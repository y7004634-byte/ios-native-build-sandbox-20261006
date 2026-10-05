(function(root) {
  'use strict';
  const finite = Number.isFinite;
  const validPoint = p => Array.isArray(p) && p.length === 2 && p.every(finite) &&
    Math.abs(p[0]) <= 180 && Math.abs(p[1]) <= 85.051129;
  function parse(value) {
    if (!value || !validPoint(value.center) || !finite(value.metersPerPoint) || value.metersPerPoint <= 0) return null;
    // Construct a new object: arbitrary Apple place metadata cannot cross this boundary.
    return {center: value.center.slice(), metersPerPoint: value.metersPerPoint,
      bearing: finite(value.bearing) ? ((value.bearing % 360) + 360) % 360 : 0,
      heading: finite(value.heading) ? value.heading : 0,
      rider: validPoint(value.rider) ? value.rider.slice() : null};
  }
  function zoom(meters, latitude, offset = 1) {
    return Math.max(12, Math.min(21, Math.log2(78271.516964 * Math.cos(latitude * Math.PI / 180) / meters) + offset));
  }
  function meters(zoom, latitude, offset = 1) {
    return 78271.516964 * Math.cos(latitude * Math.PI / 180) / Math.pow(2, zoom - offset);
  }
  const api = {parse, zoom, meters};
  if (typeof module !== 'undefined') module.exports = api;
  root.NLSCContract = api;
})(typeof window !== 'undefined' ? window : globalThis);
