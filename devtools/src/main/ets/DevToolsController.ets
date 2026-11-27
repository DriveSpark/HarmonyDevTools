export interface DevToolAction {
  readonly id: string;
  readonly title: string;
  readonly group: string;
  readonly icon?: Resource;
  readonly onSelect: () => void;
}

export class DevToolsController {
  private actions: Map<string, DevToolAction> = new Map<string, DevToolAction>();
  private listeners: Set<() => void> = new Set<() => void>();
  private panelOpen: boolean = false;
  private pendingAction?: DevToolAction;
  private panelBack?: () => void;
  private overlayBack?: () => boolean;
  private disposed: boolean = false;

  get isOpen(): boolean {
    return this.panelOpen;
  }

  getTools(): DevToolAction[] {
    return Array.from(this.actions.values());
  }

  register(action: DevToolAction): () => void {
    if (this.disposed) { return () => {}; }
    const entry: DevToolAction = {
      id: action.id, title: action.title, group: action.group, icon: action.icon, onSelect: (): void => action.onSelect()
    };
    this.actions.set(entry.id, entry);
    this.notify();
    return (): void => {
      if (this.actions.get(entry.id) === entry) {
        this.actions.delete(entry.id);
        this.notify();
      }
    };
  }

  subscribe(listener: () => void): () => void {
    if (this.disposed) { return () => {}; }
    this.listeners.add(listener);
    return (): void => { this.listeners.delete(listener); };
  }

  open(): void {
    if (this.disposed || this.panelOpen) { return; }
    this.pendingAction = undefined;
    this.panelOpen = true;
    this.notify();
  }

  close(): boolean {
    return this.dismiss();
  }

  bindPanelBack(handler: () => void): () => void {
    if (this.disposed) { return () => {}; }
    this.panelBack = handler;
    return (): void => { if (this.panelBack === handler) { this.panelBack = undefined; } };
  }

  bindOverlayBack(handler: () => boolean): () => void {
    if (this.disposed) { return () => {}; }
    this.overlayBack = handler;
    return (): void => { if (this.overlayBack === handler) { this.overlayBack = undefined; } };
  }

  handleBack(): boolean {
    if (!this.panelOpen) { return this.overlayBack?.() ?? false; }
    if (this.panelBack) { this.panelBack(); } else { this.close(); }
    return true;
  }

  private dismiss(action?: DevToolAction): boolean {
    this.pendingAction = action;
    if (!this.panelOpen) { return false; }
    this.panelOpen = false;
    this.notify();
    return true;
  }

  select(id: string): void {
    const action = this.actions.get(id);
    if (action && this.panelOpen) { this.dismiss(action); }
  }

  // The host may present its own sheet as soon as the native dismissal completes.
  panelDidDisappear(): void {
    const action = this.pendingAction;
    this.pendingAction = undefined;
    if (action && this.actions.get(action.id) === action) {
      action.onSelect();
    }
  }

  dispose(): void {
    this.disposed = true;
    this.actions.clear();
    this.close();
    this.panelBack = undefined;
    this.overlayBack = undefined;
    this.listeners.clear();
  }

  private notify(): void {
    Array.from(this.listeners).forEach((listener: () => void): void => { listener(); });
  }
}
