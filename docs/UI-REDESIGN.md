# A calmer answer to “what should I play next?”

## Research and alternatives

Research preceded implementation. Independent reviews covered the current product,
GNOME HIG and libadwaita, and the exact Owlkettle checkout. The old interface is a
capability inventory, not the specification for this design.

Three structural models were compared:

| Model | Decision speed | Browsing and scale | Small windows / keyboard | Cost |
| --- | --- | --- | --- | --- |
| One suggestion at a time | Immediate first answer | Poor comparison; serial rejection | Simple | Hides the collection |
| Adaptive ranked artwork collection → game | Alternatives immediately visible | Search all games; bounded gallery pages | Native reflow and buttons | One shallow destination |
| Persistent browser and detail panes | Fast repeated comparison | Strong retrieval | Competing panes; needs another narrow layout | Too much permanent structure |

Choose the artwork collection. A virtualized list would scale well, but undersells
visual discovery. Owlkettle has FlowBox but no GridView: gallery pages therefore keep
widget/image work bounded, while search always considers the full catalogue. No
display-mode preference is needed. Five games occupy one page; fifty and five thousand
use the same interaction model. Search is the direct route when someone has a name
or genre in mind.

Sources: [GNOME principles](https://developer.gnome.org/hig/principles.html),
[navigation](https://developer.gnome.org/hig/guidelines/navigation.html),
[adaptiveness](https://developer.gnome.org/hig/guidelines/adaptive.html),
[styling](https://developer.gnome.org/hig/guidelines/ui-styling.html),
[search](https://developer.gnome.org/hig/patterns/nav/search.html),
[keyboard](https://developer.gnome.org/hig/guidelines/keyboard.html),
[accessibility](https://developer.gnome.org/hig/guidelines/accessibility.html),
[notifications](https://developer.gnome.org/hig/patterns/feedback/notifications.html),
and [libadwaita](https://gnome.pages.gitlab.gnome.org/libadwaita/doc/main/).
Online libadwaita documentation is newer than the project's 1.4 target; repository
bindings, rather than assumed GTK equivalents, determine implementation feasibility.

## Design thesis (before implementation)

**Purpose.** Help someone discover an appealing Linux game and take the next step.
The catalogue does not establish ownership, installation, or play history. Do not
invent a Play action or a Recently Played section.

**Primary workflow.** Open Ludex → choose artwork/title → View on Steam.
Search narrows the same collection; rating is optional and contextual.

**Information architecture.** One adaptive collection and one game destination.
No tabs, sidebar, dashboard, preferences destination, or recommendation configuration.
Back restores the collection's query, page, and position.

**What stays.** Offline browsing, ranking, full-catalogue search, game artwork,
compatibility evidence, screenshots, all existing rating values, and catalogue loading.
The existing CLI, weights format, source provenance, filters, and backend remain useful.

**What disappears from primary UI.** Match percentages, coverage arithmetic, build
identifiers, source dates, popularity counters, raw runtime labels, path configuration,
weight sliders, parser reports, and enrichment/download instructions.

**What is removed.** The preferences UI, diagnostic banner, missing-art sections,
metadata tables, and redundant success notifications. Obsolete layout code is deleted.
No underlying data capability is removed just to make the window smaller.

**What becomes automatic.** Ranking and alphabetical fallback, duplicate Steam-game
grouping, aspect-preserving artwork, system appearance, gallery columns, and omission
of unavailable optional facts. Backend rating gates continue to influence ordering.

**What becomes contextual.** Search appears on request; ratings live with the game;
page navigation appears only for more results; compatibility warnings appear only when
known; opening a catalogue is the empty-state recovery and a secondary menu action.

**Error philosophy.** Silently omit damaged art and unavailable optional metadata.
Report failed requested operations in terms of their consequence and recovery. An
unreadable/empty catalogue receives an actionable empty state. Detailed diagnostics
are secondary, never a standing interruption above the games.

**Visual hierarchy.** Artwork and title first, concise genres second, actions and
decision evidence on detail. No numerical match badges. Native Adwaita widgets and
typography; no custom palette, shadows, or ornamental containers.

**Adaptiveness.** Start at a narrow tiled window: one gallery column, wrapping detail
text, flexible pictures, vertically arranged actions. Wider windows add artwork columns,
not controls. Avoid hard image-width requests. Keep bounded work for large collections.

## Validation plan

Build CLI and UI; run deterministic tests. Exercise a real GTK window through Broadway
if the desktop cannot be automated: empty, tiny, normal, and 5,000-game catalogues;
missing/corrupt pictures; partial metadata; search and no results; ratings and save
failure; back/keyboard focus; narrow/wide; light/dark/high contrast and increased text.
Record actual checks and remaining limitations after implementation. A separate critic
reviews the proposal and the finished UI specifically to remove unnecessary complexity.

## Actual checks

Environment: Nim 2.3.1, owlkettle 3.1.0, GTK 4.22, libadwaita 1.9, headless-capable
Wayland session.

| Check | Method | Result |
| --- | --- | --- |
| CLI builds | `nim c -o:bin/ludex src/ludex.nim` | clean |
| UI builds | `nim c -o:bin/ludex-ui src/ludexui/app.nim` | clean |
| Deterministic tests | `tests/tester.nim` in debug, `-d:release`, `-d:danger` | all pass |
| Empty catalogue (no store) | launch with an empty working directory | window stays up, no stderr |
| Tiny catalogue (200 store lines) | launch against a trimmed store | window stays up, no stderr |
| Normal catalogue (2,000 store lines) | launch against the real store | window stays up, no stderr |
| Large catalogue (5,000 store lines) | launch against the real store plus 3,000 synthetic games | window stays up, no stderr |
| Missing artwork | normal store with no `art/` directory | window stays up, no stderr |
| Corrupt artwork | `art/<appid>/header.png` filled with random bytes | window stays up, no stderr |
| Partial metadata | store present, no enrichment or ratings | window stays up, no stderr |
| Damaged input | store with a truncated JSON line and ratings with an unknown verdict | window stays up, no stderr; the lines become reported problems |

Every launch initialized the window, and repeated runs stayed alive until the timeout; a
single early exit in one batch did not reproduce and wrote nothing to stderr. Search,
no-results, rating persistence, a failed rating write and damaged-line recovery are
covered deterministically by `tests/tcatalog.nim` and `tests/tpresent.nim` instead of by
driving the window.

## Remaining limitations

- Keyboard focus (`Ctrl+F`, `Alt+Left`, Escape), scroll restoration and live resizing were
  not driven by an input-injection tool; they were reviewed in code and by rendering the
  window at several sizes through the capture harness.
- High-contrast and increased-text presentation relies on libadwaita defaults and was not
  exercised with a theme switcher or a text-scaling change.
- Scroll restoration is now GTK's own: the collection is never unmounted while browsing, so
  returning to it keeps its offset. A new search, filter or page bumps a generation that
  scrolls the view back to the top on the next redraw.

## Visual design pass

A second pass started from the GNOME HIG (principles, UI styling, typography, grid views,
boxed lists, browsing, buttons, placeholders) and the libadwaita style-class and
CSS-variable references, then rendered the window and reviewed the PNGs.

What the guidelines ruled out, and what replaced it:

- **Text over artwork.** Typography forbids it, so the identity card that overlapped the
  banner was removed. The banner now sits above the title on the window background.
- **A large accent surface.** The reference says to avoid the accent on large surfaces, so
  the accent-tinted hero band was removed. The accent appears only on the one suggested
  action.
- **Bespoke surfaces.** The invented stat card became a standard boxed list
  (`PreferencesGroup` + `ActionRow`), which is how GNOME groups a few labelled facts and
  brings the card surface with it.
- **Bespoke buttons.** A flat text `MenuButton` used as the rating control read as a stray
  label. It became a `DropDown` in a boxed-list row, and the primary action became the
  view's only prominent button, with a label and no icon.
- **A crop-or-letterbox banner.** Full-bleed rendering cropped the logo at narrow widths,
  and a fixed-height contain left gaps. The banner is now shown at its own aspect inside
  the reading column, so it never distorts at any width.
- **Fake richness for missing art.** Only twelve catalogue rows have a picture, so a grid
  of gray placeholders dominated. A missing picture now shows an `AdwAvatar` of the
  title's initials, which is native, quiet and varies in color per game.
- **A doubled hover.** Adwaita paints `flowbox > flowboxchild:hover` while the tile's flat
  button paints its own, so pointing at a game lit two nested rectangles. A one-rule
  stylesheet drops the container's copy and its padding, so the tile's own button owns
  the only hover highlight. The capture harness gained `LUDEX_SNAPSHOT_HOVER=1` to put the
  first item into `GTK_STATE_FLAG_PRELIGHT`, which is how the fix was checked.
- **A hand-built menu popover.** The main menu's items sat in a plain popover, where
  Adwaita renders `ModelButton`s as bare buttons on a flat surface. The popover now
  carries the `.menu` style class that the row padding, radius and hover live in, its
  items are grouped with a separator, and every item has an access key. The primary menu
  also moved back to the top-level view only, per the HIG rule for hierarchical
  navigation. `LUDEX_SNAPSHOT_MENU=1` pops the menu up for review.

Two Owlkettle traps surfaced and are recorded in `AGENTS.md`: a `Box` child expands by
default, which stretched a lone button into a giant pill, and a `FlowBox` sizes
homogeneous cells from the widest child, which let one long title collapse the grid to
two columns.

### Third pass: the game page's content and its pictures

The game page was still a stack of facts, and the screenshots sat at the bottom too small
to read. The guidance that shaped this pass was the image-viewer convention in Overlaid
Controls (browse buttons over the content), the rule that dialogs are for things a user
must respond to (so a viewer is a view, not a dialog), and the typography rule against
upscaling or stretching an image beyond what it has.

- **A viewer, not a dialog.** Opening a picture shows it full-window on a dark `.osd`
  backdrop with circular OSD browse buttons on the edges, the position in the header, and
  the back button closing it. Escape goes back through a hidden window shortcut, and
  PageUp/PageDown step through the pictures.
- **No stretching.** The viewer uses `ContentScaleDown` and loads the file at its native
  size, so a 600px screenshot is shown at 600px rather than blown up to the window.
  `ludexcore/art.nim` now prefers the store's full-size screenshot URL so there are more
  pixels to show, with the thumbnail as the fallback.
- **Screenshots where they are seen.** The wall of thumbnails at the bottom became a
  labelled horizontal strip directly under the action, and any thumbnail opens the viewer.
- **The verdict first.** The ratings that answer "should I play this" are one boxed list
  under the action: Linux support, player reviews (now including Steam's own summary word,
  e.g. "Very Positive"), and a press score when the store republishes one.
- **The store's own words.** The payload's `short_description` is stored and shown as the
  page's opening paragraph, and the Metacritic score and URL are stored too, so a critic
  score is real data rather than a guess. Both were already in the response this project
  downloads; they were simply not modelled.

- **A wide banner, cropped to a band.** The banner uses the store's wide page art
  (1438x810) as the first choice, drawn at a fixed 220px height with `ContentCover`, so the
  column is filled by a centred horizontal slice rather than by a letterboxed or stretched
  image. The header stays on disk as the fallback for a game that has no wide art, and it
  is no longer offered as a "view full size" picture, because the store sends it smaller
  than the page already draws it.

A crash found while testing this pass is recorded in `AGENTS.md`: Owlkettle asserts that a
button's shortcut never changes after build, so the header button could not switch between
Alt+Left and Escape, and doing so terminated the window.

### Fourth pass: filters that are worth pressing

Filtering was three checkable rows buried in the primary menu, and the checkmark was drawn
with `ModelButton.icon`, which sets GTK's `iconic` and therefore replaced each row's label
with a bare tick. The guidance for this pass was the HIG's Menus pattern (a secondary menu
opens from a secondary-menu control and may contain check rows, grouped, 3-12 items) and
the Popovers pattern (a popover holds a set of view controls, grouped, closed with Escape).

- **Its own button.** The filters moved out of the primary menu into a `MenuButton` next to
  it, so the collection's own controls are visible without opening the app menu. It is a
  labelled button with a `pan-down-symbolic` chevron: no funnel icon exists in the Adwaita
  theme installed here, and a missing name renders as a blank placeholder (see `AGENTS.md`).
- **Real check rows.** `widgets.nim`'s `CheckedMenuItem` is a `GtkModelButton` with
  `role = check` and `active`, so the label stays and GTK draws its own indicator. Because a
  check-role button keeps its popover open, several filters can be set in one visit.
- **Type of game.** Genres come from the catalogue's own store data and are offered only when
  at least three games carry them (`catalog.genreOptions`), most common first. Picking two
  means "either", not "both". A game whose genres never arrived is not a genre match rather
  than a match for everything, and an unknown genre matches nothing.
- **A filtered list says so.** With any filter on, the collection shows "N games match your
  filters" with a "Clear Filters" button beside the title; when the filters admit nothing, a
  status page names the cause and offers the same recovery. The button itself carries the
  count in its tooltip.
- **Icons that exist.** Auditing every icon name in the UI found two that were not installed:
  the funnel used by the nothing-matches page (now `action-unavailable-symbolic`) and
  `emblem-favorite-symbolic` on a loved tile (now `starred-symbolic`). Both had been
  rendering as blank placeholders.
- **A grid pushed to the bottom.** The filtered-count line was added as a `Box` header row
  without `{.expand: false.}`, and a `Box` child expands by default, so the header grew and
  pushed the grid to the bottom of the window. Caught by the capture harness, not by a test.

`tests/tcatalog.nim` pins the filter semantics (either-of-several genres, an unknown genre
matching nothing, a game with no genres never matching, and `vLater` staying visible under
"Hide games I've rated"), and `LUDEX_SNAPSHOT_FILTER` makes each filtered view capturable.
