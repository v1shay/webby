(function (global) {
  "use strict";

  const BRAILLE = 0x2800;
  const CANVAS_X_SCALE = 2.0;
  const CANVAS_Y_SCALE = 1.0;

  function round(x) {
    return Math.floor(x + 0.5);
  }

  function pointDist(x0, y0, x1, y1) {
    const dx = x1 - x0;
    const dy = y1 - y0;
    return Math.sqrt(dx * dx + dy * dy);
  }

  function pointLineDist(x0, y0, deltaX, deltaY, adj, length) {
    return Math.abs(deltaY * x0 - deltaX * y0 + adj) / length;
  }

  function pointLineDistWithin(
    x0, y0, deltaX, deltaY, adj, length,
    dist, x1, y1, x2, y2
  ) {
    if (
      (x0 < x1 - dist && x0 < x2 - dist) ||
      (x0 > x1 + dist && x0 > x2 + dist) ||
      (y0 < y1 - dist && y0 < y2 - dist) ||
      (y0 > y1 + dist && y0 > y2 + dist)
    ) {
      return 0;
    }

    if (pointLineDist(x0, y0, deltaX, deltaY, adj, length) < dist) {
      return 1;
    }

    return 0;
  }

  class D3Point {
    constructor(x, y, z) {
      this.x = x;
      this.y = y;
      this.z = z;
    }

    scale(factor) {
      this.x *= factor;
      this.y *= factor;
      this.z *= factor;
    }

    rotateAroundXAxis(angle) {
      const y = this.y * Math.cos(angle) - this.z * Math.sin(angle);
      const z = this.y * Math.sin(angle) + this.z * Math.cos(angle);
      this.y = y;
      this.z = z;
    }

    rotateAroundYAxis(angle) {
      const x = this.z * Math.sin(angle) + this.x * Math.cos(angle);
      const z = this.z * Math.cos(angle) - this.x * Math.sin(angle);
      this.x = x;
      this.z = z;
    }

    rotateAroundZAxis(angle) {
      const x = this.x * Math.cos(angle) - this.y * Math.sin(angle);
      const y = this.x * Math.sin(angle) + this.y * Math.cos(angle);
      this.x = x;
      this.y = y;
    }

    middle(that) {
      return new D3Point(
        0.5 * (that.x + this.x),
        0.5 * (that.y + this.y),
        0.5 * (that.z + this.z)
      );
    }

    normalize() {
      const dist = Math.sqrt(
        this.x * this.x + this.y * this.y + this.z * this.z
      );
      this.x /= dist;
      this.y /= dist;
      this.z /= dist;
    }
  }

  class Triangle {
    constructor(a, b, c) {
      this.a = a;
      this.b = b;
      this.c = c;
    }
  }

  class Edge {
    constructor(p0, p1) {
      this.p0 = p0;
      this.p1 = p1;
    }

    equals(that) {
      return (
        (this.p0 === that.p0 && this.p1 === that.p1) ||
        (this.p0 === that.p1 && this.p1 === that.p0)
      );
    }
  }

  class Model {
    constructor(triangles) {
      this.triangles = triangles || [];
      this._allPoints = null;
      this._allEdges = null;
    }

    facingTowardsCamera(t) {
      const ax = t.b.x - t.a.x;
      const ay = t.b.y - t.a.y;
      const az = t.b.z - t.a.z;

      const bx = t.c.x - t.a.x;
      const by = t.c.y - t.a.y;
      const bz = t.c.z - t.a.z;

      const crossY = az * bx - ax * bz;
      return crossY < 0;
    }

    collectPointsAndEdges(masking) {
      const pointSet = new Set();
      const edges = [];

      const edgeExists = (candidate) => {
        for (let i = 0; i < edges.length; i++) {
          if (edges[i].equals(candidate)) return true;
        }
        return false;
      };

      for (const triangle of this.triangles) {
        if (masking && !this.facingTowardsCamera(triangle)) {
          continue;
        }

        pointSet.add(triangle.a);
        pointSet.add(triangle.b);
        pointSet.add(triangle.c);

        const triEdges = [
          new Edge(triangle.a, triangle.b),
          new Edge(triangle.b, triangle.c),
          new Edge(triangle.c, triangle.a),
        ];

        for (const edge of triEdges) {
          if (!edgeExists(edge)) {
            edges.push(edge);
          }
        }
      }

      return {
        points: Array.from(pointSet),
        edges,
      };
    }

    ensureAllGeometry() {
      if (this._allPoints && this._allEdges) return;
      const result = this.collectPointsAndEdges(false);
      this._allPoints = result.points;
      this._allEdges = result.edges;
    }

    scale(factor) {
      this.ensureAllGeometry();
      for (const point of this._allPoints) {
        point.scale(factor);
      }
    }

    rotateAroundXAxis(angle) {
      this.ensureAllGeometry();
      for (const point of this._allPoints) {
        point.rotateAroundXAxis(angle);
      }
    }

    rotateAroundYAxis(angle) {
      this.ensureAllGeometry();
      for (const point of this._allPoints) {
        point.rotateAroundYAxis(angle);
      }
    }

    rotateAroundZAxis(angle) {
      this.ensureAllGeometry();
      for (const point of this._allPoints) {
        point.rotateAroundZAxis(angle);
      }
    }
  }

  function makeIcosahedron(refines) {
    const t = (1.0 + Math.sqrt(5.0)) / 2.0;

    const points = [
      new D3Point(-1,  t,  0),
      new D3Point( 1,  t,  0),
      new D3Point(-1, -t,  0),
      new D3Point( 1, -t,  0),
      new D3Point( 0, -1,  t),
      new D3Point( 0,  1,  t),
      new D3Point( 0, -1, -t),
      new D3Point( 0,  1, -t),
      new D3Point( t,  0, -1),
      new D3Point( t,  0,  1),
      new D3Point(-t,  0, -1),
      new D3Point(-t,  0,  1),
    ];

    for (const p of points) p.normalize();

    let triangles = [
      new Triangle(points[0],  points[11], points[5]),
      new Triangle(points[0],  points[5],  points[1]),
      new Triangle(points[0],  points[1],  points[7]),
      new Triangle(points[0],  points[7],  points[10]),
      new Triangle(points[0],  points[10], points[11]),
      new Triangle(points[1],  points[5],  points[9]),
      new Triangle(points[5],  points[11], points[4]),
      new Triangle(points[11], points[10], points[2]),
      new Triangle(points[10], points[7],  points[6]),
      new Triangle(points[7],  points[1],  points[8]),
      new Triangle(points[3],  points[9],  points[4]),
      new Triangle(points[3],  points[4],  points[2]),
      new Triangle(points[3],  points[2],  points[6]),
      new Triangle(points[3],  points[6],  points[8]),
      new Triangle(points[3],  points[8],  points[9]),
      new Triangle(points[4],  points[9],  points[5]),
      new Triangle(points[2],  points[4],  points[11]),
      new Triangle(points[6],  points[2],  points[10]),
      new Triangle(points[8],  points[6],  points[7]),
      new Triangle(points[9],  points[8],  points[1]),
    ];

    for (let i = 0; i < refines; i++) {
      const next = [];

      for (const tri of triangles) {
        const a = tri.a.middle(tri.b);
        const b = tri.b.middle(tri.c);
        const c = tri.c.middle(tri.a);

        a.normalize();
        b.normalize();
        c.normalize();

        next.push(new Triangle(tri.a, a, c));
        next.push(new Triangle(tri.b, b, a));
        next.push(new Triangle(tri.c, c, b));
        next.push(new Triangle(a, b, c));
      }

      triangles = next;
    }

    return new Model(triangles);
  }

  class BrailleCanvas {
    constructor(rows, columns) {
      this.rows = rows;
      this.columns = columns;
      this.data = [];
      for (let y = 0; y < rows; y++) {
        const row = new Array(columns);
        row.fill(BRAILLE);
        this.data.push(row);
      }
    }

    clear() {
      for (let y = 0; y < this.rows; y++) {
        this.data[y].fill(BRAILLE);
      }
    }

    get(y, x) {
      if (
        x < 0 || x >= this.columns ||
        y < 0 || y >= this.rows
      ) {
        return 0;
      }
      return this.data[y][x];
    }

    set(y, x, value) {
      if (
        x >= 0 && x < this.columns &&
        y >= 0 && y < this.rows
      ) {
        this.data[y][x] = value;
      }
    }

    toRows() {
      const rows = [];
      for (let y = 0; y < this.rows; y++) {
        let s = "";
        for (let x = 0; x < this.columns; x++) {
          s += String.fromCodePoint(this.data[y][x]);
        }
        rows.push(s);
      }
      return rows;
    }

    toString() {
      return this.toRows().join("\n") + "\n";
    }
  }

  function fillPoints(
    x0, yStart, inc,
    x1, y1, x2, y2,
    deltaX, deltaY, adj, length,
    canvas, maxY, width
  ) {
    const x = x0;

    for (
      let yi = yStart;
      yi >= 0 && yi <= maxY;
      yi += inc
    ) {
      const y = yi;

      const pointDist1 = pointDist(x, yi, x1, y1);
      const pointDist2 = pointDist(x, yi, x2, y2);

      const filledPoint = canvas.get(yi, x0);
      let runePoint = 0;

      if (filledPoint > BRAILLE && filledPoint <= 0x28ff) {
        runePoint = filledPoint - BRAILLE;
      }

      runePoint |= pointLineDistWithin(
        x - 0.45, y - 0.4,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 0;

      runePoint |= pointLineDistWithin(
        x - 0.45, y - 0.2,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 1;

      runePoint |= pointLineDistWithin(
        x - 0.45, y + 0.2,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 2;

      runePoint |= pointLineDistWithin(
        x + 0.45, y - 0.4,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 3;

      runePoint |= pointLineDistWithin(
        x + 0.45, y - 0.2,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 4;

      runePoint |= pointLineDistWithin(
        x + 0.45, y + 0.2,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 5;

      runePoint |= pointLineDistWithin(
        x - 0.45, y + 0.4,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 6;

      runePoint |= pointLineDistWithin(
        x + 0.45, y + 0.4,
        deltaX, deltaY, adj, length,
        width, x1, y1, x2, y2
      ) << 7;

      if (
        runePoint === 0 ||
        pointDist1 + pointDist2 > length + 2
      ) {
        return;
      }

      canvas.set(yi, x0, BRAILLE + runePoint);
    }
  }

  function wideLineProjection(
    canvas,
    x2, x1,
    y2, y1,
    width
  ) {
    if (x2 < x1) {
      let tmpX = x2;
      let tmpY = y2;
      x2 = x1;
      y2 = y1;
      x1 = tmpX;
      y1 = tmpY;
    }

    const maxX = canvas.columns;
    const maxY = canvas.rows;

    const deltaX = x2 - x1;
    const deltaY = y2 - y1;

    let m;
    if (Math.abs(x2 - x1) < 0.000001) {
      m = NaN;
    } else {
      m = (y2 - y1) / (x2 - x1);
    }

    const b = y1 - m * x1;
    const adj = x2 * y1 - y2 * x1;
    const length = Math.sqrt(
      (y2 - y1) * (y2 - y1) +
      (x2 - x1) * (x2 - x1)
    );

    let y0;

    for (
      let x0 = round(x1 - width - 1);
      x0 <= round(x2 + width + 1) && x0 <= maxX;
      x0++
    ) {
      if (!Number.isNaN(m)) {
        y0 = m * x0 + b;

        if (
          (y0 < y1 && y0 < y2) ||
          (y0 > y1 && y0 > y2)
        ) {
          y0 = y1;
        }
      } else {
        y0 = y1;
      }

      fillPoints(
        x0, round(y0), 1,
        x1, y1, x2, y2,
        deltaX, deltaY, adj, length,
        canvas, maxY, width
      );

      fillPoints(
        x0, round(y0), -1,
        x1, y1, x2, y2,
        deltaX, deltaY, adj, length,
        canvas, maxY, width
      );
    }
  }

  function projectEdgesOntoCanvas(
    edges,
    canvas,
    offsetRow,
    offsetColumn,
    width
  ) {
    const offsetX = 0.0;
    const offsetZ = -10.0;

    for (const edge of edges) {
      const x0 =
        (edge.p0.x + offsetX) *
          CANVAS_X_SCALE +
        offsetColumn;

      const x1 =
        (edge.p1.x + offsetX) *
          CANVAS_X_SCALE +
        offsetColumn;

      const y0 =
        (edge.p0.z + offsetZ) *
          CANVAS_Y_SCALE +
        offsetRow;

      const y1 =
        (edge.p1.z + offsetZ) *
          CANVAS_Y_SCALE +
        offsetRow;

      wideLineProjection(
        canvas,
        x0, x1,
        y0, y1,
        width
      );
    }
  }

  class Ico {
    constructor(
      width,
      height,
      xOffset,
      yOffset,
      joints,
      scale
    ) {
      this.width = width;
      this.height = height;
      this.xOffset = xOffset;
      this.yOffset = yOffset;
      this.joints = joints;

      this.canvas = new BrailleCanvas(
        height,
        width
      );

      this.model = makeIcosahedron(1);
      this.model.scale(scale);
    }

    RotateX(f) {
      // This odd naming is intentional.
      // It matches the original public implementation.
      this.model.rotateAroundZAxis(f);
    }

    RotateY(f) {
      this.model.rotateAroundXAxis(f);
    }

    RenderRows() {
      const result =
        this.model.collectPointsAndEdges(true);

      projectEdgesOntoCanvas(
        result.edges,
        this.canvas,
        this.yOffset,
        this.xOffset,
        0.6
      );

      const rows = this.canvas.toRows();
      this.canvas.clear();
      return rows;
    }

    Render() {
      return this.RenderRows().join("\n") + "\n";
    }
  }

  global.ico = {
    New: function (
      width,
      height,
      xOffset,
      yOffset,
      joints,
      scale
    ) {
      return new Ico(
        width,
        height,
        xOffset,
        yOffset,
        joints,
        scale
      );
    },
  };
})(typeof window !== "undefined" ? window : globalThis);
