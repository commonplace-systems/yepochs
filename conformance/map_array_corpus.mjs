// Ruling 8.1: before yepochs claims cross-language support for maps or arrays,
// at least one UPSTREAM-AUTHORED crossing vector per claimed type must exist.
// The five inherited vectors are text and deletes only.
//
// Authored by upstream `yjs`, not by yelixer — that is the entire point: every
// other fixture in this repo puts yelixer's encoder on both sides.
import * as Y from 'yjs'
import { mkdirSync, writeFileSync } from 'node:fs'

const hex = u => Buffer.from(u).toString('hex')
// ⚠️ Captures ONE update. Multi-operation setups must be wrapped in
// Y.transact, or each operation emits its own update and only the LAST is kept
// -- the earlier ones are silently lost, the replica buffers the survivor as
// pending, and the next edit becomes a no-op that captures null.
const cap = (d, f, label) => {
  let o = null
  const h = u => { o = u }
  d.on('update', h); f(); d.off('update', h)
  if (o === null) throw new Error(`no update captured for ${label} -- did the operation no-op?`)
  return o
}
const mk = c => { const d = new Y.Doc(); d.clientID = c; return d }

const ROOT = process.argv[2]
const cases = []

// `view` is captured per-case because maps and arrays are not text.
function addCase(name, num, build, viewOf) {
  const updates = build()
  const o = mk(1); for (const u of updates) Y.applyUpdate(o, u)
  const view = viewOf(o)
  const r = mk(1); for (const u of [...updates].reverse()) Y.applyUpdate(r, u)
  const pathIndependent =
    hex(Y.encodeStateAsUpdate(o)) === hex(Y.encodeStateAsUpdate(r)) &&
    JSON.stringify(viewOf(r)) === JSON.stringify(view)
  cases.push({ name, num, updates: updates.map(hex), view, pathIndependent,
               final: hex(Y.encodeStateAsUpdate(o)) })
}

const mapView = d => ({ map: d.getMap('m').toJSON() })
const arrView = d => ({ array: d.getArray('a').toArray() })

addCase('map-concurrent-distinct-keys', 6, () => {
  const a = mk(100), b = mk(200)
  return [cap(a, () => a.getMap('m').set('k1', 'v1'), 'map k1'),
          cap(b, () => b.getMap('m').set('k2', 'v2'), 'map k2')]
}, mapView)

addCase('map-sequential-overwrite', 7, () => {
  const a = mk(100); const u0 = cap(a, () => a.getMap('m').set('k', 'first'), 'overwrite setup')
  const b = mk(200); Y.applyUpdate(b, u0)
  return [u0, cap(b, () => b.getMap('m').set('k', 'second'), 'overwrite')]
}, mapView)

addCase('map-delete-key', 8, () => {
  const a = mk(100)
  const u0 = cap(a, () => Y.transact(a, () => {
    a.getMap('m').set('k1', 'v1'); a.getMap('m').set('k2', 'v2')
  }), 'map-delete-key setup')
  const b = mk(200); Y.applyUpdate(b, u0)
  return [u0, cap(b, () => b.getMap('m').delete('k2'), 'map-delete-key delete')]
}, mapView)

addCase('array-sequential-inserts', 9, () => {
  const a = mk(100); const u0 = cap(a, () => a.getArray('a').insert(0, ['x', 'y']), 'array setup')
  const b = mk(200); Y.applyUpdate(b, u0)
  return [u0, cap(b, () => b.getArray('a').insert(2, ['z']), 'array insert')]
}, arrView)

addCase('array-delete-element', 10, () => {
  const a = mk(100); const u0 = cap(a, () => a.getArray('a').insert(0, ['x', 'y', 'z']), 'array del setup')
  const b = mk(200); Y.applyUpdate(b, u0)
  return [u0, cap(b, () => b.getArray('a').delete(1, 1), 'array delete')]
}, arrView)

for (const c of cases) {
  const dir = `${ROOT}/${String(c.num).padStart(3, '0')}-${c.name}`
  mkdirSync(dir, { recursive: true })
  writeFileSync(`${dir}/updates.hex`, c.updates.join('\n') + '\n')
  writeFileSync(`${dir}/expected_view.json`, JSON.stringify(c.view) + '\n')
  writeFileSync(`${dir}/upstream.json`,
    JSON.stringify({ generator: 'yjs', version: '13.6.32', path_independent: c.pathIndependent }) + '\n')
  writeFileSync(`${dir}/upstream_final.hex`, c.final + '\n')
  console.log(`${c.num} ${c.name}: ${c.updates.length} updates, view=${JSON.stringify(c.view)}, path_independent=${c.pathIndependent}`)
}
