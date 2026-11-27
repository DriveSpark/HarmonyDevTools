import { FrameNode } from '@kit.ArkUI';
import { DevToolsInspectorNode, isDevToolsSurfaceNode } from './DevToolsNodeTree';

interface DevToolsInspectorEdges {
  top?: string;
  right?: string;
  bottom?: string;
  left?: string;
}

interface DevToolsInspectorStyle {
  backgroundColor?: string;
  fontColor?: string;
  fontSize?: string;
  padding?: string | DevToolsInspectorEdges;
  margin?: string | DevToolsInspectorEdges;
}

interface DevToolsInspectorProperties {
  $attrs?: DevToolsInspectorStyle;
}

function edgeText(raw?: string | DevToolsInspectorEdges): string {
  if (!raw) { return ''; }
  let edges: DevToolsInspectorEdges;
  if (typeof raw === 'string') {
    if (!raw.startsWith('{')) { return parseFloat(raw) === 0 ? '' : raw; }
    try { edges = JSON.parse(raw) as DevToolsInspectorEdges; } catch { return ''; }
  } else { edges = raw; }
  if (!edges || !edges.top || !edges.right || !edges.bottom || !edges.left) { return ''; }
  const values = [edges.top, edges.right, edges.bottom, edges.left];
  return values.every((side: string): boolean => parseFloat(side) === 0) ? '' : values.join(' ');
}

/** Read the selected frame only. No component text, user input or embedded-surface content goes in the report. */
export function describeDevToolsNode(node: DevToolsInspectorNode, frame: FrameNode | null): string {
  let id = node.inspectorId;
  let width = node.rect.right - node.rect.left;
  let height = node.rect.bottom - node.rect.top;
  let style: DevToolsInspectorStyle | undefined;
  try {
    if (frame && !frame.isDisposed() && frame.isAttached()) {
      id = frame.getId();
      const size = frame.getMeasuredSize();
      if (Number.isFinite(size.width) && Number.isFinite(size.height)) {
        width = size.width;
        height = size.height;
      }
      const type = node.componentType;
      if (!isDevToolsSurfaceNode(type) && type !== 'TextInput' && type !== 'TextArea' && type !== 'RichEditor' && type !== 'Search') {
        style = (frame.getInspectorInfo() as DevToolsInspectorProperties).$attrs;
      }
    }
  } catch { /* Geometry from the current inspector snapshot remains available during detachment. */ }
  const lines: string[] = [
    '控件 ID：' + (id || '未设置'), '节点编号：' + node.uniqueId,
    '控件尺寸：' + Math.round(width) + ' × ' + Math.round(height) + ' px',
    '窗口位置：' + Math.round(node.rect.left) + ', ' + Math.round(node.rect.top) + ' px'
  ];
  if (style) {
    if (typeof style.backgroundColor === 'string' && style.backgroundColor && style.backgroundColor !== '#00000000') {
      lines.push('背景色：' + style.backgroundColor);
    }
    if (typeof style.fontColor === 'string' && style.fontColor) { lines.push('文字颜色：' + style.fontColor); }
    if (typeof style.fontSize === 'string' && style.fontSize) { lines.push('字号：' + style.fontSize); }
    const padding = edgeText(style.padding);
    const margin = edgeText(style.margin);
    if (padding) { lines.push('内边距（上右下左）：' + padding); }
    if (margin) { lines.push('外边距（上右下左）：' + margin); }
  }
  return lines.join('\n');
}
