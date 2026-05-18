/**
 * Geohash buckets for nearby driver candidate reads.
 */

"use strict";

const BASE32 = "0123456789bcdefghjkmnpqrstuvwxyz";

function encodeGeohash(latitude, longitude, precision = 6) {
  const lat = Number(latitude);
  const lng = Number(longitude);
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return "";
  let idx = 0;
  let bit = 0;
  let evenBit = true;
  let geohash = "";
  let latMin = -90;
  let latMax = 90;
  let lonMin = -180;
  let lonMax = 180;

  while (geohash.length < precision) {
    if (evenBit) {
      const lonMid = (lonMin + lonMax) / 2;
      if (lng >= lonMid) {
        idx = idx * 2 + 1;
        lonMin = lonMid;
      } else {
        idx = idx * 2;
        lonMax = lonMid;
      }
    } else {
      const latMid = (latMin + latMax) / 2;
      if (lat >= latMid) {
        idx = idx * 2 + 1;
        latMin = latMid;
      } else {
        idx = idx * 2;
        latMax = latMid;
      }
    }
    evenBit = !evenBit;
    if (++bit === 5) {
      geohash += BASE32.charAt(idx);
      bit = 0;
      idx = 0;
    }
  }
  return geohash;
}

function geohashNeighbors(hash) {
  const h = String(hash ?? "").trim();
  if (!h) return [];
  const out = new Set([h]);
  const last = h.slice(-1);
  const idx = BASE32.indexOf(last);
  if (idx < 0) return [h];
  const prefix = h.slice(0, -1);
  if (idx > 0) out.add(prefix + BASE32.charAt(idx - 1));
  if (idx < BASE32.length - 1) out.add(prefix + BASE32.charAt(idx + 1));
  if (h.length > 1) {
    out.add(h.slice(0, -1));
    out.add(h + BASE32.charAt(0));
  }
  return [...out];
}

function haversineKm(lat1, lng1, lat2, lng2) {
  const a1 = Number(lat1);
  const a2 = Number(lng1);
  const b1 = Number(lat2);
  const b2 = Number(lng2);
  if (![a1, a2, b1, b2].every(Number.isFinite)) return Number.POSITIVE_INFINITY;
  const R = 6371;
  const dLat = ((b1 - a1) * Math.PI) / 180;
  const dLng = ((b2 - a2) * Math.PI) / 180;
  const x =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((a1 * Math.PI) / 180) *
      Math.cos((b1 * Math.PI) / 180) *
      Math.sin(dLng / 2) ** 2;
  return 2 * R * Math.asin(Math.sqrt(x));
}

module.exports = {
  encodeGeohash,
  geohashNeighbors,
  haversineKm,
};
