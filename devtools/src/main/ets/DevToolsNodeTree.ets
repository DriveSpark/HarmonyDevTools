import { DevToolsBounds } from './DevToolsLauncher';

export interface DevToolsInspectorViewport {
  windowX: number;
  windowY: number;
  width: number;
  height: number;
  density: number;
}

export interface DevToolsNodeTraits {
  visible: boolean;
  clipsChildren: boolean;
}

export interface DevToolsInspectorNode {
  uniqueId: number;
  inspectorId: string;
  componentType: string;
  // ArkUI Inspector reports transformed, window-relative physical pixel bounds.
  rect: DevToolsBounds;
  visibleRect: DevToolsBounds;
}

export type DevToolsNodeTreeStatus = 'ready' | 'partial' | 'unavailable' | 'oversized';

export interface DevToolsNodeSnapshot {
  nodes: DevToolsInspectorNode[];
  status: DevToolsNodeTreeStatus;
}

interface DevToolsTreeAttributes {
  id?: string;
}

interface DevToolsTreeElement {
  $type?: string;
  $ID?: number;
  $attrs?: DevToolsTreeAttributes;
  $rect?: string;
  $children?: DevToolsTreeElement[];
}

export const DEVTOOLS_INSPECTOR_NODE_LIMIT: number = 1536;
export const DEVTOOLS_INSPECTOR_JSON_LIMIT: number = 2 * 1024 * 1024;
const MAX_TREE_DEPTH: number = 128;

export function isDevToolsSurfaceNode(componentType: string): boolean {
  return componentType === 'Web' || componentType === 'Canvas' || componentType === 'XComponent' ||
    componentType === 'UIExtensionComponent' || componentType === 'SecurityUIExtensionComponent' ||
    componentType === 'IsolatedComponent' || componentType === 'EmbeddedComponent' || componentType === 'FormComponent';
}

function intersectRect(a: DevToolsBounds, b: DevToolsBounds): DevToolsBounds | undefined {
  const left = Math.max(a.left, b.left);
  const top = Math.max(a.top, b.top);
  const right = Math.min(a.right, b.right);
  const bottom = Math.min(a.bottom, b.bottom);
  return right > left && bottom > top ? { left: left, top: top, right: right, bottom: bottom } : undefined;
}

function inspectorRect(raw?: string): DevToolsBounds | undefined {
  if (typeof raw !== 'string' || raw.length > 160) { return undefined; }
  // Device format: [left,top],[right,bottom]. The preview inspector serializes x,y,width,height.
  const corners = /^\s*\[\s*([^,\]]+),([^,\]]+)\]\s*,?\s*\[\s*([^,\]]+),([^,\]]+)\]\s*$/.exec(raw);
  const parts = corners ? corners.slice(1) : raw.split(',');
  if (parts.length !== 4 || parts.some((part: string): boolean => part.trim().length === 0)) { return undefined; }
  const left = Number(parts[0]);
  const top = Number(parts[1]);
  const right = Number(parts[2]) + (corners ? 0 : left);
  const bottom = Number(parts[3]) + (corners ? 0 : top);
  if (!Number.isFinite(left) || !Number.isFinite(top) || !Number.isFinite(right) || !Number.isFinite(bottom) ||
    right <= left || bottom <= top) { return undefined; }
  return { left: left, top: top, right: right, bottom: bottom };
}

/** Only the drawing surface and pointer events use local vp. Selection and clipping stay in window px. */
export function localDevToolsNodeRect(rect: DevToolsBounds, viewport: DevToolsInspectorViewport): DevToolsBounds {
  return { left: rect.left / viewport.density - viewport.windowX, top: rect.top / viewport.density - viewport.windowY,
    right: rect.right / viewport.density - viewport.windowX, bottom: rect.bottom / viewport.density - viewport.windowY };
}

export function readDevToolsNodeTree(raw: string, viewport: DevToolsInspectorViewport, overlayUniqueId: number,
  probe: (uniqueId: number) => DevToolsNodeTraits | undefined): DevToolsNodeSnapshot {
  if (raw.length > DEVTOOLS_INSPECTOR_JSON_LIMIT) { return { nodes: [], status: 'oversized' }; }
  let root: DevToolsTreeElement;
  try { root = JSON.parse(raw) as DevToolsTreeElement; } catch { return { nodes: [], status: 'unavailable' }; }
  if (!root || root.$type !== 'root' || (root.$children !== undefined && !Array.isArray(root.$children))) {
    return { nodes: [], status: 'unavailable' };
  }
  const snapshot: DevToolsNodeSnapshot = { nodes: [], status: 'ready' };
  const windowRect: DevToolsBounds = {
    left: viewport.windowX * viewport.density, top: viewport.windowY * viewport.density,
    right: (viewport.windowX + viewport.width) * viewport.density, bottom: (viewport.windowY + viewport.height) * viewport.density
  };
  let visited = 0;
  const visit = (element: DevToolsTreeElement, clip: DevToolsBounds, depth: number): void => {
    visited++;
    if (!element || typeof element.$type !== 'string') { return; }
    const uniqueId = element.$ID;
    const id = typeof element.$attrs?.id === 'string' ? element.$attrs.id : '';
    if (id === 'devtools_overlay' || id === 'devtools_cover' || (overlayUniqueId >= 0 && uniqueId === overlayUniqueId)) {
      return;
    }
    const traits = typeof uniqueId === 'number' && uniqueId >= 0 ? probe(uniqueId) : undefined;
    if (traits && !traits.visible) { return; }
    const rect = inspectorRect(element.$rect);
    const visible = rect ? intersectRect(rect, clip) : undefined;
    const childClip = traits?.clipsChildren ? visible : clip;
    const children = element.$children;
    if (childClip && Array.isArray(children) && !isDevToolsSurfaceNode(element.$type)) {
      // The last sibling is tested first. Descendants precede their enclosing component.
      for (let i = children.length - 1; i >= 0; i--) {
        if (depth >= MAX_TREE_DEPTH || visited >= DEVTOOLS_INSPECTOR_NODE_LIMIT) { snapshot.status = 'partial'; break; }
        visit(children[i], childClip, depth + 1);
      }
    }
    if (rect && visible && traits && uniqueId !== undefined) {
      snapshot.nodes.push({ uniqueId: uniqueId, inspectorId: id, componentType: element.$type, rect: rect, visibleRect: visible });
    }
  };
  visit(root, windowRect, 0);
  return snapshot;
}

export function findDevToolsNodeHits(snapshot: DevToolsNodeSnapshot, viewport: DevToolsInspectorViewport,
  localX: number, localY: number): DevToolsInspectorNode[] {
  const x = (localX + viewport.windowX) * viewport.density;
  const y = (localY + viewport.windowY) * viewport.density;
  return snapshot.nodes.filter((node: DevToolsInspectorNode): boolean => {
    const r = node.visibleRect;
    return x >= r.left && x < r.right && y >= r.top && y < r.bottom;
  });
}

export function cycleDevToolsNodeHit(index: number, count: number, direction: number): number {
  return count > 0 ? (index + direction + count) % count : -1;
}

export function sameDevToolsNodeRect(a: DevToolsBounds, b: DevToolsBounds): boolean {
  return a.left === b.left && a.right === b.right && a.top === b.top && a.bottom === b.bottom;
}

export function sameDevToolsNodeTree(a: DevToolsNodeSnapshot, b: DevToolsNodeSnapshot): boolean {
  if (a.status !== b.status || a.nodes.length !== b.nodes.length) { return false; }
  return a.nodes.every((node: DevToolsInspectorNode, i: number): boolean => {
    const other = b.nodes[i];
    return node.uniqueId === other.uniqueId && node.inspectorId === other.inspectorId &&
      node.componentType === other.componentType && sameDevToolsNodeRect(node.rect, other.rect) &&
      sameDevToolsNodeRect(node.visibleRect, other.visibleRect);
  });
}
