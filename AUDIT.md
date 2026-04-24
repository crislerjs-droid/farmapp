# Field Commander — Pre-Code Handoff Audit

Status check before porting this single-file HTML app to a proper web application. Written specifically for Claude Code (or any developer) picking this up cold.

## At a glance

- **Single file, ~3,750 lines** (one HTML, one inline `<script>` block of ~3,469 lines of JS, plus a <style> block)
- **~161 functions** organized by feature area (map, print, mix/sub, bills, orders, reports, traits, data I/O)
- **33 top-level `let` globals**, **18 `const` tables/configs**
- **No build step, no dependencies** beyond Leaflet (CDN) and the Esri tile server
- **Persistence is one JSON blob in `localStorage`** under key `fc_v7`
- **No duplicate function definitions, no TODO/FIXME markers** — the code is reasonably clean despite its size
- **10 unused/dead functions** identified (safe to delete during port)

## What works well

These parts are solid and should port cleanly:

**Map rendering**. The core `renderSVG` function builds clean, print-ready maps using an area-weighted polygon centroid for label placement and a shared aspect-ratio padding to fit any page. It handles overview maps, per-cluster close-ups, highlighted (active) fields, context outlines, and mix/trait coloring. All of it is pure function of inputs — no DOM or storage side effects.

**Unit conversion layer** (`UNIT_LIQUID`, `UNIT_DRY`, `UNIT_OPAQUE`, `convertUnits`, `normUnit`). Clean, covers the ag-spray common cases (gal ↔ oz ↔ pt ↔ qt for liquids, lb ↔ oz ↔ ton for dry), gracefully flags unconvertible units like `bag` / `tote`. Pure functions.

**Print popup pattern**. Every PDF-style output (purchase orders, coding reports, applicator reports, bill coding sheets, field maps, trait recaps) uses the same infrastructure: build an HTML body, open a popup window, inject print CSS that sizes to letter paper at 0.4"–0.5" margins, trigger `window.print()`. Works cross-browser and includes Save-as-PDF on every platform.

**Trait system** (herbicide-tolerance per variety). Named crops, configurable trait colors via palette, per-variety assignments, auto-guess from variety name with override. The data flow is clean — one `traitFor(crop, variety)` function reads through the override layer and returns a normalized trait object.

**Applicator report** — grouping by `(date, crop)`, optional `$/acre` rate, detailed field breakdown on a second page. This is the monthly-bill-reconcile workflow; it matches the real-world paper bills you'd be checking against.

**Overview map logic** — late-stage fix after six iterations. It uses per-cluster context from the close-up view, plus a hardcoded `BRIDGE_FARMS` list for explicit in-between farms. Works well for the current farm; should be per-user-configurable in production.

**Aspect-ratio-aware SVG bounds**. Every printed map pads its bbox to match the printable area of letter paper, which keeps the map filling the page regardless of the natural shape of the highlighted fields.

## What needs work before a real port

### 1. State management — this is the #1 refactor target

The app has **33 top-level `let` globals** (`F`, `subcategories`, `purchases`, `bills`, `varietyTraits`, `traitColors`, `applicatorRates`, `farmInfo`, etc.) that all the rendering functions read directly. Every data mutation is an in-place edit of a global, followed by a call to `save()` which re-serializes the entire blob into `localStorage`.

For a web app this has to go. The right move:

- **Introduce a store abstraction** (Redux-free is fine — even a single `getState()` / `dispatch()` pattern or a simple event-emitter over typed state). Functions get state passed in rather than reaching for globals.
- **Each entity gets its own table/collection**, not a single blob. Fields, subcategories, mixes, purchases, bills, applicators, trait colors, farm info all become independent records with IDs.
- **Optimistic local updates + server sync**. The localStorage model where "save = rewrite everything" doesn't scale and has no conflict resolution.

The big win here: once state is structured, server endpoints become obvious. One REST endpoint per resource, standard CRUD.

### 2. Data model — mostly good, a few rough edges

What's already fine:
- **Fields** have stable integer IDs, reasonable shape: `{id, name, farm, acres, crop, variety, plantDate, points}`
- **Subcategories → Mixes → Field assignments** is well-nested and matches how the user thinks
- **Purchase items carry `splits[]`** array for dollar allocation across crops/categories (migrated from the earlier single-crop field)
- **Bills use the same split shape** — consistent

What needs attention:
- **No concept of user/tenant**. Everything is single-farm. Multi-tenant requires adding `ownerId` (or `farmId`) to every top-level entity.
- **Field IDs are locally assigned integers** (`nid++`). For a DB-backed system these should be UUIDs or server-assigned IDs. Existing data can keep integer IDs as a `legacy_id` during migration.
- **`F` is a flat array scanned linearly everywhere** (`F.find(x => x.id === id)`). Fine for 500 fields, but index by ID in a proper store.
- **Some entities are nested inside subcategories** (`subcategories.spray[].mixes[].fields[]`) rather than normalized. The nested `fields[fid]` map is convenient for reads but awkward for queries like "what did applicator X do in May?". The app currently does this with a nested triple-loop — flat applied-events table would be much cleaner.
- **`VC` and `CC` (variety and crop color maps) are objects that get mutated** in place and persisted. Should become proper normalized tables.
- **No created/updated timestamps** on most entities. Purchases have dates but nothing else does.
- **`plantDate` is a string** with no validation. Sometimes empty string, sometimes ISO.

### 3. Known migration needs

When switching from localStorage JSON to a DB, these data shapes need a one-time transform:

- **Purchase items with legacy `crop` / `category` fields** → `splits[]` array. (Already handled by `migratePurchaseSplits()` in the app — port that logic.)
- **Legacy field events in mixes without `status`** → default to `'planned'`
- **Subcategories without mixes** → should just be dropped, they're UI artifacts of an abandoned wizard step

### 4. Security / input validation

Single-user, offline app → zero validation. In a multi-user web app:

- **XSS**: The app uses an `esc()` helper called ~173 times, but there are **34 `.innerHTML = ...` assignments** and **143 `document.getElementById` references**. Spot-check every `innerHTML` write — any user-supplied string needs to go through `esc()`. Examples I verified are safe: `esc(f.name)`, `esc(p.vendor)`, `esc(it.product)` — these are all escaped. But the pattern is easy to miss in a review. **In the new app, use a framework with auto-escaping templates** (React, Vue, Svelte, Lit — any of them) and this whole category goes away.
- **Shapefile import** — the app reads uploaded files with no size limit, format validation beyond the extension, or sanity check on polygon geometry. A malicious or malformed file can crash the parse. Put a server-side validation layer.
- **Number inputs** — acres, rates, prices are parsed with `parseFloat` and flow into totals. No min/max/NaN guards. Frontend validation + server sanity checks needed.

### 5. UI wiring

- **123 inline `onclick="..."` handlers** referencing global function names. In a component framework these become event handlers on elements. Easy but tedious conversion.
- **34 `.innerHTML = ...` rerenders**. These are ad hoc — the app re-builds HTML strings and slams them into container elements. A declarative component model handles this for you.
- **Panels and modals are just absolutely-positioned divs** toggled by adding/removing a class. Works fine; a component library will have better accessibility (focus trap, ESC key, aria roles).
- **26 `alert()`, 5 `confirm()`, 1 `prompt()` calls** — all should become proper modal/toast components in the new app.

### 6. Print workflow — will need a fallback

The current "open popup, inject CSS, call `window.print()`" pattern works but:
- **Some iOS/mobile browsers block popups** in tricky ways. On iPad Safari this often needs a user gesture that persists to the new window.
- **No PDF saved to disk** on the server — every print is ephemeral, produced client-side.

In a web app with a server backend, add **server-side PDF generation** (headless Chrome, Playwright, puppeteer) as a fallback. Client requests a report, server returns a PDF file. Keeps the current popup flow for desktop (fast, works now) and adds the server path for mobile and for emailing/archiving.

### 7. Hardcoded values that should be config

These are currently literals in the JS:

- **`BRIDGE_FARMS = new Set(['Sisk', 'Home Farm'])`** — farm names baked in. Should be a per-user setting.
- **`spendCrops = ['Rice', 'Beans', 'Corn', 'Wheat', 'Milo', 'Cotton', 'Other']`** — user-editable in theory, but no UI. Add one.
- **`spendCategories = ['Herbicide', 'Fung+Insect', 'Fertilizer', 'Seed', 'Adjuvant', 'Other']`** — same.
- **`TRAITS.Rice` and `TRAITS.Soybeans`** — the trait taxonomy itself. Should probably stay as a shared reference table but be extensible.
- **`TRAIT_PALETTE`** — 10 preset colors. Fine as a constant.
- **`LABEL_ZOOM_THRESHOLD = 15`** — field-name label threshold. Arguably a user preference.
- **`PAGE_ASPECT = 0.84`** — print aspect ratio. Only matters if someone wants landscape or A4 later; keep as constant for now.
- **Farm info (`farmInfo`)** is user-editable — that's fine already.

### 8. Dead code

Safe to delete during port (confirmed zero call sites):

- `resetTraitColor`
- `getActiveMix`
- `doFilter`
- `pickMixColor`
- `batCrop`, `batPlantDate`, `batVar` (replaced by `batApply` but old ones linger)
- `hideMenuOnClick`
- `toggleEventPanel`
- `impFiles`

About 200–300 lines of reclaimable space.

## Proposed DB schema (starting point)

```
users { id, email, farm_name, address, phone, email_contact }
fields { id, user_id, name, farm, acres, crop, variety, plant_date, points JSONB, created_at, updated_at }
varieties { user_id, name, color, crop } -- replaces VC
crops { user_id, name, color } -- replaces CC
variety_traits { user_id, variety_name, trait_code }
trait_colors { user_id, crop, trait_code, color }
subcategories { id, user_id, category, name, sort_order }
mixes { id, subcategory_id, name, color, products JSONB }
field_assignments { id, mix_id, field_id, status, applied_date, applicator }
  -- this is the flat view of what's currently in mx.fields[fid]
vendors { id, user_id, name, account_number }
applicators { id, user_id, name, rate_per_acre }
delivery_locations { id, user_id, name }
purchases { id, user_id, vendor, location, type, date }
purchase_items { id, purchase_id, product, qty, unit, unit_price, splits JSONB }
bills { id, user_id, vendor, bill_number, bill_date, stated_total, notes }
bill_lines { id, bill_id, description, amount, splits JSONB }
spend_categories { user_id, name, sort_order }
spend_crops { user_id, name, sort_order }
bridge_farms { user_id, farm_name }
```

`points`, `splits`, and mix `products` stay as JSONB — they're schema-free arrays where relational splitting would be overkill. Everything else normalizes cleanly.

## Recommended porting order

1. **Set up project skeleton** — pick a framework (React/Next, SvelteKit, whatever). Establish the store/state abstraction.
2. **Port the pure-function layer first** — unit conversion, `renderSVG`, polygon centroid, cluster grouping, trait logic. These have no side effects and no DB.
3. **Build the DB schema, seed with test data**.
4. **Port the map view** — Leaflet integration, field rendering, selection, labels. Biggest UI surface, unlocks visual feedback fast.
5. **Port one workflow end-to-end as proof of concept** — I'd pick purchase orders (small, well-defined, has PDF output).
6. **Expand to mixes/subcategories** — the most complex domain logic.
7. **Reports** (applicator, coding) — these are read-only views, easier after the data is flowing.
8. **Bills + reconciliation** — last, since it depends on everything else.
9. **Multi-tenant / auth** — add once the single-user version is solid.

## Quirks worth calling out

- **Purchase items can have zero splits** — `itemSplits()` synthesizes a blank one at the line total. Keep this behavior.
- **`fmtDate` formats `YYYY-MM-DD` → `M/D/YYYY`** — the display format. Store canonical, format on render.
- **`updateMix` / `saveMixToSub`** — the mix editor can save back into a mix OR create a new one, both flows share a lot of code. Worth untangling in the port.
- **The "selected fields" set (`sel`)** is mutation-heavy. It's a `Set` of IDs used by batch operations (batch crop, batch variety, mark applied). In the new version, this should be a derived state (checkboxes in a list) rather than a mutable global.
- **Some labels assume zero minutes/hours in ISO dates** — `plantDate.split('-')[2]` etc. If you add time-of-day, watch for this.
- **Browser localStorage has a ~5MB limit**. With 225 fields of moderate complexity the current save file is around 500KB. Not a problem, but the 5MB ceiling means you can't scale this to a commercial product without a real backend.

## Summary

The app is in reasonable shape for a ~3,700-line single-file project. The domain logic is clear, the data model is mostly consistent (after the recent `splits[]` migration), and the rendering code is cleanly factored. The biggest lift is **moving from globals-plus-localStorage to a proper state store with a backend**. Everything else is straightforward porting.

For Claude Code or whoever takes this on: start with the pure functions, use this document as the map, and expect about a week of careful work to get feature parity on a modern stack.
