import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';

export type DevToolsInfoPage = 'appinfo' | 'deviceinfo' | 'screeninfo';
export type DevToolsVisualId = 'ruler' | 'colorpicker' | 'inspector' | 'borders';
export type DevToolsBuiltinId = DevToolsInfoPage | DevToolsVisualId | 'cpu' | 'memory' | 'developer' | 'logs' | 'crash';
export type DevToolsBuiltinGroup = 'common' | 'performance' | 'visual';
export const DEVTOOLS_GROUPS: DevToolsBuiltinGroup[] = ['common', 'performance', 'visual'];

export interface DevToolsBuiltinSetting {
  readonly id: DevToolsBuiltinId;
  readonly group: DevToolsBuiltinGroup;
  readonly checked: boolean;
}

type DevToolsManagerDialog = 'none' | 'save' | 'reset' | 'saved' | 'restored' | 'failed';
type DevToolsMoveResult = 'moved' | 'unchanged' | 'lastInGroup';

const CATALOG_KEY = 'builtin_layout';

const BUILTIN_TOOLS: DevToolsBuiltinSetting[] = [
  { id: 'appinfo', group: 'common', checked: true },
  { id: 'deviceinfo', group: 'common', checked: true },
  { id: 'screeninfo', group: 'common', checked: true },
  { id: 'developer', group: 'common', checked: true },
  { id: 'logs', group: 'common', checked: true },
  { id: 'cpu', group: 'performance', checked: true },
  { id: 'memory', group: 'performance', checked: true },
  { id: 'crash', group: 'performance', checked: true },
  { id: 'ruler', group: 'visual', checked: true },
  { id: 'colorpicker', group: 'visual', checked: true },
  { id: 'inspector', group: 'visual', checked: true },
  { id: 'borders', group: 'visual', checked: true }
];

export function isDevToolsBuiltinId(id: string): boolean {
  return BUILTIN_TOOLS.some((tool: DevToolsBuiltinSetting): boolean => tool.id === id);
}

function defaultTools(): DevToolsBuiltinSetting[] {
  return BUILTIN_TOOLS.slice();
}

function readTools(raw: string): DevToolsBuiltinSetting[] {
  if (!raw) { return defaultTools(); }
  try {
    const saved = JSON.parse(raw) as DevToolsBuiltinSetting[];
    if (!Array.isArray(saved)) { return defaultTools(); }
    const defaults = defaultTools();
    const seen = new Set<string>();
    const current: DevToolsBuiltinSetting[] = [];
    for (const item of saved) {
      if (!item || !isDevToolsBuiltinId(item.id) ||
        seen.has(item.id) || !DEVTOOLS_GROUPS.includes(item.group) ||
        typeof item.checked !== 'boolean') { continue; }
      current.push({ id: item.id, group: item.group, checked: item.checked });
      seen.add(item.id);
    }
    for (const tool of defaults) {
      if (!seen.has(tool.id)) { current.push(tool); }
    }
    const ordered: DevToolsBuiltinSetting[] = [];
    for (const group of DEVTOOLS_GROUPS) {
      const tools = current.filter((tool: DevToolsBuiltinSetting): boolean => tool.group === group);
      if (tools.length === 0) { return defaults; }
      ordered.push(...tools);
    }
    return ordered;
  } catch {
    return defaultTools();
  }
}

@ObservedV2
export class DevToolsCatalogState {
  @Trace private saved: DevToolsBuiltinSetting[] = defaultTools();
  @Trace private draft?: DevToolsBuiltinSetting[];
  @Trace dialog: DevToolsManagerDialog = 'none';
  private store?: preferences.Preferences;

  get editing(): boolean { return this.draft !== undefined; }

  load(context?: common.Context): void {
    if (!context || this.editing) { return; }
    try {
      this.store = preferences.getPreferencesSync(context, { name: 'devtools_catalog' });
      const raw = this.store.getSync(CATALOG_KEY, '');
      this.saved = typeof raw === 'string' ? readTools(raw) : defaultTools();
    } catch {
      this.store = undefined;
    }
  }

  tools(group: DevToolsBuiltinGroup, manage: boolean = false): DevToolsBuiltinSetting[] {
    const source = manage && this.draft ? this.draft : this.saved;
    return source.filter((tool: DevToolsBuiltinSetting): boolean =>
      tool.group === group && (tool.checked || (manage && this.editing)));
  }

  beginEditing(): void {
    if (!this.draft) { this.draft = this.saved.slice(); }
  }

  toggle(id: DevToolsBuiltinId): void {
    if (!this.draft) { return; }
    this.draft = this.draft.map((tool: DevToolsBuiltinSetting): DevToolsBuiltinSetting => {
      if (tool.id !== id) { return tool; }
      return { id: tool.id, group: tool.group, checked: !tool.checked };
    });
  }

  move(id: DevToolsBuiltinId, target: DevToolsBuiltinId): DevToolsMoveResult {
    const draft = this.draft;
    if (!draft || id === target) { return 'unchanged'; }
    const from = draft.findIndex((tool: DevToolsBuiltinSetting): boolean => tool.id === id);
    const to = draft.findIndex((tool: DevToolsBuiltinSetting): boolean => tool.id === target);
    if (from < 0 || to < 0) { return 'unchanged'; }
    const source = draft[from];
    if (!draft.some((tool: DevToolsBuiltinSetting): boolean => tool.group === source.group && tool.id !== id)) {
      return 'lastInGroup';
    }
    const next = draft.slice();
    next.splice(from, 1);
    next.splice(to, 0, { id: source.id, group: draft[to].group, checked: source.checked });
    this.draft = next;
    return 'moved';
  }

  finishEditing(): void {
    if (this.draft && this.persist(this.draft)) { this.dialog = 'saved'; }
  }

  requestReset(): void {
    if (this.editing) { this.dialog = 'reset'; }
  }

  requestManagerBack(): boolean {
    if (this.dialog !== 'none') {
      this.dismissNotice();
      return true;
    }
    if (!this.editing) { return false; }
    this.dialog = 'save';
    return true;
  }

  // Returns true when the manager should close after resolving its back confirmation.
  resolveConfirmation(positive: boolean): boolean {
    if (this.dialog === 'save' && this.draft) {
      if (positive && !this.persist(this.draft)) { return false; }
      this.leaveManager();
      return true;
    }
    if (this.dialog === 'reset') {
      this.dialog = 'none';
      if (positive && this.persist(defaultTools())) { this.dialog = 'restored'; }
    }
    return false;
  }

  dismissNotice(): void {
    if (this.dialog === 'saved' || this.dialog === 'restored' || this.dialog === 'failed') { this.dialog = 'none'; }
  }

  leaveManager(): void {
    this.draft = undefined;
    this.dialog = 'none';
  }

  private persist(next: DevToolsBuiltinSetting[]): boolean {
    const store = this.store;
    if (store) {
      try {
        const previous = store.getSync(CATALOG_KEY, '');
        store.putSync(CATALOG_KEY, JSON.stringify(next));
        try {
          store.flushSync();
        } catch {
          // putSync updates the shared Preferences cache before flushSync writes the file.
          store.putSync(CATALOG_KEY, previous);
          this.dialog = 'failed';
          return false;
        }
        this.saved = next;
        this.draft = undefined;
        return true;
      } catch {
        // Keep the current draft available if the preferences store rejected the write.
      }
    }
    this.dialog = 'failed';
    return false;
  }
}
