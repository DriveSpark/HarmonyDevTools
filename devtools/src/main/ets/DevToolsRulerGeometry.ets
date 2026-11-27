import { DevToolsBounds } from './DevToolsLauncher';

export const DEVTOOLS_RULER_MARKER_SIZE: number = 60;

export interface DevToolsRulerPoint {
  x: number;
  y: number;
}

export interface DevToolsRulerDistances {
  left: number;
  right: number;
  top: number;
  bottom: number;
}

function fraction(distance: number, travel: number, previous: number = 0): number {
  return travel > 0 ? Math.max(0, Math.min(1, distance / travel)) : previous;
}

/** Positions are local vp inside the safe host rectangle. Only the displayed distances are in px. */
export class DevToolsRulerGeometry {
  readonly width: number;
  readonly height: number;
  readonly cardWidth: number;
  readonly cardHeight: number;
  private readonly cardMargin: number;
  private readonly cardTravelX: number;
  private readonly cardTravelY: number;

  constructor(bounds: DevToolsBounds, hostShortSide: number) {
    this.width = Math.max(0, bounds.right - bounds.left);
    this.height = Math.max(0, bounds.bottom - bounds.top);
    const frameWidth = Math.min(this.width, hostShortSide > 0 ? hostShortSide : this.width);
    this.cardMargin = Math.min(15, frameWidth / 2);
    this.cardWidth = frameWidth - this.cardMargin * 2;
    this.cardHeight = Math.min(100, this.height);
    this.cardTravelX = this.width - frameWidth;
    this.cardTravelY = this.height - this.cardHeight;
  }

  markerPosition(anchor?: DevToolsRulerPoint): DevToolsRulerPoint {
    if (anchor) { return { x: anchor.x * this.width, y: anchor.y * this.height }; }
    const radius = DEVTOOLS_RULER_MARKER_SIZE / 2;
    return { x: Math.min(this.width, this.width / 2 + radius),
      y: Math.min(this.height, this.height / 2 + radius) };
  }

  markerFraction(x: number, y: number): DevToolsRulerPoint {
    return { x: fraction(x, this.width), y: fraction(y, this.height) };
  }

  cardPosition(anchor?: DevToolsRulerPoint): DevToolsRulerPoint {
    if (anchor) { return { x: this.cardMargin + anchor.x * this.cardTravelX, y: anchor.y * this.cardTravelY }; }
    return { x: this.cardMargin, y: Math.max(0, this.height - 150) };
  }

  cardFraction(x: number, y: number, previous?: DevToolsRulerPoint): DevToolsRulerPoint {
    return { x: fraction(x - this.cardMargin, this.cardTravelX, previous?.x),
      y: fraction(y, this.cardTravelY, previous?.y) };
  }

  distances(marker: DevToolsRulerPoint, density: number, includedStatusBar: number): DevToolsRulerDistances {
    const left = Math.round(marker.x * density);
    const top = Math.round(marker.y * density);
    return { left: left, right: Math.round(this.width * density) - left,
      top: top + Math.round(includedStatusBar * density), bottom: Math.round(this.height * density) - top };
  }
}
