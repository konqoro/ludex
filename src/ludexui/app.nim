## A quiet, artwork-first answer to “what should I play next?”.
##
## One automatically ordered collection leads to one game. The window never
## pretends catalogue entries are installed games: its handoff is View on Steam.
## FlowBox supplies native adaptive columns; bounded pages keep image decoding
## and widget work independent of catalogue size. Search still covers every game.
## Catalog owns disk data, present owns wording, and this module owns interaction.

import std/[options, tables]

import owlkettle
import owlkettle/adw
import owlkettle/bindings/gtk

import ludexcore/[models, query, taste]
import ludexui/[catalog, present, widgets]
when defined(ludexSnapshot):
  import std/[os, strutils]
  import ludexui/snapshot

const
  PageSize = 24
  Caption = StyleClass("caption")
  Dim = StyleClass("dim-label")
  Success = StyleClass("success")
  Caution = StyleClass("warning")
  Danger = StyleClass("error")
  Accent = StyleClass("accent")
  Grid = StyleClass("ludex-grid")
  Menu = StyleClass("menu")
  Osd = StyleClass("osd")
  Body = StyleClass("body")

const ReadingWidth = 820
  ## The width the game page's column is clamped to. The banner is sized from
  ## its own picture at this width, so it fills the column exactly rather than
  ## leaving letterbox bars that a fixed height would.

const GridStyles = """
.ludex-grid > flowboxchild {
  padding: 0;
  background-color: transparent;
}
.ludex-grid > flowboxchild:hover,
.ludex-grid > flowboxchild:active {
  background-color: transparent;
}
"""
  ## Adwaita paints `flowbox > flowboxchild:hover`, and the tile's flat button
  ## paints its own, so a pointer hover showed two nested highlights. The button
  ## owns the interaction, so the container's copy is dropped and its padding
  ## moves back to the grid's own spacing.

var initialWindowSize* = (1000, 720)
  ## The shipping window size. The development capture build overrides it from
  ## the environment before the window is built.

viewable App:
  catalog: Catalog
  selected: Option[Release]
  viewer: Option[int] ## the picture being shown full-window, if any
  filters: Filters = Filters() ## the collection's own switches
  query: string
  searching: bool
  page: int
  items: seq[BrowseItem]
  pictures: Table[string, Option[Pixbuf]]
  galleryScroll: ScrollMemory = newScrollMemory()
  toasts: ToastQueue = newToastQueue()

proc chooseCatalog(app: AppState)
proc showAbout(app: AppState)
proc showDetails(app: AppState)

proc refreshItems(app: AppState) =
  app.items = app.catalog.browse(app.query, app.filters)
  app.page = min(app.page, max(0, (app.items.len - 1) div PageSize))

proc search(app: AppState; text: string) =
  app.query = text
  app.page = 0
  app.galleryScroll.reset()
  app.refreshItems()

proc closeSearch(app: AppState) =
  app.searching = false
  app.search("")

type FilterKind = enum
  fkRunsHere, fkDeckReady, fkUnjudged

func filtersActive(filters: Filters): bool =
  filters.runsHere or filters.deckReady or filters.unjudged or
    filters.genres.len > 0

func filterCount(filters: Filters): int =
  ord(filters.runsHere) + ord(filters.deckReady) + ord(filters.unjudged) +
    filters.genres.len

func filterTooltip(filters: Filters): string =
  let count = filterCount(filters)
  if count == 0: "Filter Games"
  else: "Filter Games (" & $count & " active)"

proc clearFilters(app: AppState) =
  app.filters = Filters()
  app.page = 0
  app.galleryScroll.reset()
  app.refreshItems()

proc toggleFilter(app: AppState; kind: FilterKind) =
  case kind
  of fkRunsHere: app.filters.runsHere = not app.filters.runsHere
  of fkDeckReady: app.filters.deckReady = not app.filters.deckReady
  of fkUnjudged: app.filters.unjudged = not app.filters.unjudged
  app.page = 0
  app.galleryScroll.reset()
  app.refreshItems()

proc toggleGenre(app: AppState; genre: string) =
  var index = -1
  for position, name in app.filters.genres:
    if name == genre:
      index = position
      break
  if index >= 0:
    app.filters.genres.delete(index)
  else:
    app.filters.genres.add genre
  app.page = 0
  app.galleryScroll.reset()
  app.refreshItems()

proc reload(app: AppState) =
  app.catalog = loadCatalog(app.catalog.paths)
  app.pictures.clear()
  app.refreshItems()

proc picture(app: AppState; path: string; width: int): Option[Pixbuf] =
  ## Cache failures too: a damaged picture should not be decoded on every redraw.
  let key = $width & ":" & path
  if not app.pictures.hasKey(key):
    var loaded: Option[Pixbuf]
    try:
      loaded = if width > 0:
        some loadPixbuf(path, width, -1, preserveAspectRatio = true)
      else:
        some loadPixbuf(path) ## native size, for the full-window viewer
    except CatchableError:
      discard
    if app.pictures.len >= 160:
      app.pictures.clear()
    app.pictures[key] = loaded
  result = app.pictures[key]

proc openGame(app: AppState; release: Release) =
  app.selected = some release
  app.viewer = none(int)

type GameArt = object
  background: Option[string] ## the store's wide page art, when downloaded
  header: Option[string] ## the 460x215 list image, when downloaded
  shots: seq[string] ## every screenshot file, in order

proc gameArt(app: AppState; release: Release): GameArt =
  ## The picture files for one game. Paths rather than bitmaps, because the
  ## window shows the same picture at two sizes: a thumbnail in the strip and
  ## the untouched file in the viewer.
  let files = app.catalog.artFiles(release.appid.get(0))
  result.background = files.background
  result.header = files.header
  result.shots = files.shots

func banner(art: GameArt): Option[string] =
  ## What the top picture shows. The store's wide page art is preferred because
  ## the header is only 460x215 and looks soft when the page draws it large; the
  ## header is the fallback, and the first screenshot the last resort.
  if art.background.isSome:
    result = art.background
  elif art.header.isSome:
    result = art.header
  elif art.shots.len > 0:
    result = some art.shots[0]

func media(art: GameArt): seq[string] =
  ## What the viewer can show, which is the screenshots. The banner is left out
  ## deliberately: the store sends it at 460x215, so showing it "full size" would
  ## be smaller than the page already draws it.
  art.shots

proc openViewer(app: AppState; index: int) =
  app.viewer = some index

proc closeViewer(app: AppState) =
  app.viewer = none(int)

proc stepViewer(app: AppState; delta: int) =
  ## Moving past either end stays put rather than wrapping.
  if app.selected.isNone or app.viewer.isNone:
    return
  let count = media(app.gameArt(app.selected.get)).len
  if count == 0:
    return
  app.viewer = some max(0, min(count - 1, app.viewer.get + delta))

proc rateGame(app: AppState; release: Release; verdict: Verdict) =
  if app.catalog.rate(release.appid.get, release.title, verdict):
    app.refreshItems()
  else:
    app.toasts.add(newToast("Rating wasn’t saved. Check that your ratings file is writable and try again."))

proc backButton(app: AppState): Widget =
  ## One button steps back one level: it closes the picture viewer before it
  ## leaves the game, so the header never needs a second navigation control.
  let viewing = app.viewer.isSome
  result = gui:
    Button:
      icon = if viewing: "window-close-symbolic" else: "go-previous-symbolic"
      tooltip = if viewing: "Close the Picture"
                else: "Back to Games (Alt+Left)"
      style = [ButtonFlat]
      shortcut = "<Alt>Left"
      proc clicked() =
        if app.viewer.isSome:
          app.closeViewer()
        else:
          app.selected = none(Release)

proc searchToggle(app: AppState): Widget =
  result = gui:
    ToggleButton:
      icon = "system-search-symbolic"
      tooltip = "Search Games (Ctrl+F)"
      style = [ButtonFlat]
      shortcut = "<Ctrl>F"
      state = app.searching
      proc changed(state: bool) =
        app.searching = state
        if not state:
          app.closeSearch()

proc mainMenu(app: AppState): Widget =
  ## The primary menu: app-wide commands, then the standard About item in its
  ## own group. The `.menu` popover style is what gives the rows Adwaita's
  ## full-width padding and hover; without it the items render as bare buttons.
  ## Narrowing the collection is not an app-wide command, so it lives behind its
  ## own filter button instead of being buried here.
  result = gui:
    MenuButton:
      icon = "open-menu-symbolic"
      tooltip = "Main Menu"
      style = [ButtonFlat]
      Popover:
        style = [Menu]
        Box(orient = OrientY, margin = 6):
          ModelButton:
            text = "_Open Catalogue…"
            proc clicked() = app.chooseCatalog()
          ModelButton:
            text = "_Reload"
            proc clicked() = app.reload()
          if app.catalog.problems.len > 0:
            ModelButton:
              text = "Show _Diagnostics…"
              proc clicked() = app.showDetails()
          Separator()
          ModelButton:
            text = "_About Ludex"
            proc clicked() = app.showAbout()

proc filterMenu(app: AppState): Widget =
  ## Filtering narrows the whole collection at once, so it gets its own control
  ## rather than an entry buried in the main menu. Every row is a checkable menu
  ## item, and GTK keeps a check-role popover open, so several questions can be
  ## answered in one visit. Genres come from the catalogue: a game's own store
  ## genres, or nothing when the store never answered, in which case a genre
  ## filter never counts it as a match.
  ##
  ## The icon is `view-more-symbolic`, GNOME's secondary-menu icon: a set of view
  ## options is exactly a secondary menu, and the Adwaita theme here ships no
  ## funnel to name it more literally.
  let genres = app.catalog.genreOptions()
  result = gui:
    MenuButton:
      icon = "view-more-symbolic"
      tooltip = filterTooltip(app.filters)
      style = [ButtonFlat]
      Popover:
        style = [Menu]
        Box(orient = OrientY, margin = 6):
          CheckedMenuItem:
            text = "_Runs on Linux"
            active = app.filters.runsHere
            proc clicked() = app.toggleFilter(fkRunsHere)
          CheckedMenuItem:
            text = "Steam _Deck ready"
            active = app.filters.deckReady
            proc clicked() = app.toggleFilter(fkDeckReady)
          CheckedMenuItem:
            text = "_Hide games I've rated"
            active = app.filters.unjudged
            proc clicked() = app.toggleFilter(fkUnjudged)
          if genres.len > 0:
            Separator()
            Label {.expand: false.}:
              text = "Type of Game"
              xAlign = 0
              style = [Dim]
              margin = Margin(top: 6, bottom: 3, left: 12, right: 12)
            for genre in genres:
              CheckedMenuItem:
                text = genre
                active = genre in app.filters.genres
                proc clicked() = app.toggleGenre(genre)
          if filterCount(app.filters) > 0:
            Separator()
            ModelButton:
              text = "_Clear Filters"
              proc clicked() = app.clearFilters()

proc viewerTitle(app: AppState): string =
  ## "3 of 12": where the picture sits in the game's gallery.
  if app.selected.isNone or app.viewer.isNone:
    return "Ludex"
  let count = media(app.gameArt(app.selected.get)).len
  if count == 0:
    return "Ludex"
  $min(app.viewer.get + 1, count) & " of " & $count

proc header(app: AppState): Widget =
  ## The header follows the view. The primary menu belongs to the top level, so
  ## it is hidden while reading a game, as the HIG requires of a window with
  ## hierarchical navigation.
  result = gui:
    AdwHeaderBar:
      WindowTitle {.addTitle.}:
        title = app.viewerTitle()
      if app.selected.isSome:
        insert(backButton(app)) {.addLeft.}
      else:
        insert(searchToggle(app)) {.addLeft.}
        insert(filterMenu(app)) {.addRight.}
        insert(mainMenu(app)) {.addRight.}

proc searchField(app: AppState): Widget =
  result = gui:
    Clamp:
      maximumSize = 640
      FocusSearchEntry:
        margin = Margin(top: 6, bottom: 6, left: 12, right: 12)
        text = app.query
        placeholderText = "Search games or genres"
        tooltip = "Search games or genres"
        proc changed(text: string) = app.search(text)
        proc stopSearch() = app.closeSearch()
        proc activate() =
          if app.items.len > 0:
            app.openGame(app.items[0].release)

proc emptyCollection(app: AppState): Widget =
  ## A placeholder page: heading, a line of guidance, and the one action that
  ## recovers from the empty state. The button is centred by its own box, since
  ## a status page stretches its child to the full width.
  result = gui:
    StatusPage:
      iconName = "applications-games-symbolic"
      title = "Find Your Next Game"
      description = "Open a Ludex catalogue to start exploring."
      Box(orient = OrientY):
        Button {.expand: false, hAlign: AlignCenter.}:
          text = "Open Catalogue…"
          style = [ButtonSuggested, ButtonPill]
          proc clicked() = app.chooseCatalog()

proc emptySearch(app: AppState): Widget =
  result = gui:
    StatusPage:
      iconName = "system-search-symbolic"
      title = "No Games Found"
      description = "Try a different name or genre."
      Box(orient = OrientY):
        Button {.expand: false, hAlign: AlignCenter.}:
          text = "Clear Search"
          proc clicked() = app.search("")

proc emptyFiltered(app: AppState): Widget =
  ## The catalogue has games, but the view's own switches admit none of them, so
  ## the recovery is to loosen a filter rather than to search differently.
  result = gui:
    StatusPage:
      iconName = "action-unavailable-symbolic"
      title = "Nothing Matches"
      description = "The filters are hiding every game."
      Box(orient = OrientY):
        Button {.expand: false, hAlign: AlignCenter.}:
          text = "Clear Filters"
          proc clicked() = app.clearFilters()

proc gameTile(app: AppState; item: BrowseItem): Widget =
  let release = item.release
  let files = app.catalog.artFiles(release.appid.get(0))
  let art = if files.header.isSome: app.picture(files.header.get, 240)
            else: none(Pixbuf)
  let genres = gameGenres(storeFactsOf(app.catalog.stores, release))
  let loved = app.catalog.taste.verdictOf(release.appid.get(0)) == some vLoved
  result = gui:
    Button:
      style = [ButtonFlat]
      tooltip = release.title
      Box(orient = OrientY, spacing = 8):
        sizeRequest = (240, -1)
        if art.isSome:
          Picture {.expand: false.}:
            pixbuf = art.get
            contentFit = ContentCover
            sizeRequest = (240, 112)
        else:
          Box {.expand: false.}:
            orient = OrientY
            sizeRequest = (240, 112)
            Avatar {.hAlign: AlignCenter, vAlign: AlignCenter.}:
              text = release.title
              size = 56
              showInitials = true
        Box(orient = OrientX, spacing = 6):
          BoundedLabel {.expand: true.}:
            text = release.title
            xAlign = 0
            maxChars = 22
            ellipsize = EllipsizeEnd
            style = [StyleClass("heading")]
          if loved:
            Icon {.expand: false, vAlign: AlignCenter.}:
              name = "starred-symbolic"
              pixelSize = 14
              tooltip = "You loved this"
              style = [Accent]
        if genres.len > 0:
          BoundedLabel {.expand: false.}:
            text = genres
            xAlign = 0
            maxChars = 26
            ellipsize = EllipsizeEnd
            style = [Caption, Dim]
      proc clicked() = app.openGame(release)

proc pagination(app: AppState): Widget =
  let pages = (app.items.len + PageSize - 1) div PageSize
  result = gui:
    Box(orient = OrientX, spacing = 18):
      Button {.expand: false.}:
        icon = "go-previous-symbolic"
        tooltip = "Previous Games"
        sensitive = app.page > 0
        proc clicked() =
          dec app.page
          app.galleryScroll.reset()
      Label:
        text = $(app.page + 1) & " / " & $pages
        style = [Caption, Dim]
      Button {.expand: false.}:
        icon = "go-next-symbolic"
        tooltip = "More Games"
        sensitive = app.page + 1 < pages
        proc clicked() =
          inc app.page
          app.galleryScroll.reset()

proc collection(app: AppState): Widget =
  if not app.catalog.hasGames():
    return app.emptyCollection()
  if app.items.len == 0:
    if app.query.len == 0 and filtersActive(app.filters):
      return app.emptyFiltered()
    return app.emptySearch()
  let first = app.page * PageSize
  let last = min(first + PageSize, app.items.len)
  result = gui:
    RememberedScroll:
      memory = app.galleryScroll
      Clamp:
        maximumSize = 1120
        Box(orient = OrientY, spacing = 18):
          margin = Margin(top: 18, bottom: 24, left: 12, right: 12)
          Box {.expand: false.}:
            orient = OrientX
            spacing = 12
            margin = Margin(left: 12, right: 12)
            Box(orient = OrientY, spacing = 3):
              Label {.expand: false.}:
                text = if app.query.len > 0: "Search Results" else: "Find Your Next Game"
                xAlign = 0
                wrap = true
                style = [LabelTitle2]
              if filtersActive(app.filters):
                Label {.expand: false.}:
                  text = $app.items.len & " games match your filters"
                  xAlign = 0
                  style = [Caption, Dim]
            if filtersActive(app.filters):
              Button {.expand: false, vAlign: AlignCenter.}:
                text = "Clear Filters"
                tooltip = "Show every game again"
                proc clicked() = app.clearFilters()
          FlowBox {.expand: false.}:
            style = [Grid]
            columns = 1..5
            homogeneous = true
            rowSpacing = 16
            columnSpacing = 16
            selectionMode = SelectionNone
            for index in first..<last:
              insert(gameTile(app, app.items[index]))
          if app.items.len > PageSize:
            insert(pagination(app)) {.expand: false, hAlign: AlignCenter.}

proc gtk_show_uri(display: pointer; uri: cstring; timestamp: cuint): cbool
  {.importc, cdecl.}

proc openUri(uri: string) =
  ## The one action Ludex can honestly offer: the game's Steam page.
  if uri.len > 0:
    discard gtk_show_uri(cast[pointer](gdk_display_get_default()), uri.cstring, 0)

proc toneStyle(tone: CompatibilityTone): StyleClass =
  ## Adwaita's semantic colors, which follow light, dark and high contrast.
  case tone
  of toneNegative: Danger
  of toneCaution: Caution
  of tonePositive: Success
  else: Dim

proc ratingRow(app: AppState; release: Release): Widget =
  ## The verdict as a boxed-list row with a drop-down control, the same shape
  ## GNOME uses for choosing one value from a short list.
  let current = app.catalog.taste.verdictOf(release.appid.get)
  var items = @["Not rated"]
  for verdict in Verdict:
    items.add verdictLabel(verdict)
  let selected = if current.isSome: ord(current.get) + 1 else: 0
  result = gui:
    PreferencesGroup:
      ActionRow:
        title = "Your rating"
        subtitle = "Shape future suggestions"
        DropDown {.addSuffix.}:
          items = items
          selected = selected
          proc select(item: int) =
            if item <= 0:
              if app.catalog.clearRating(release.appid.get):
                app.refreshItems()
              else:
                app.toasts.add(newToast("Rating wasn’t cleared. Check your ratings file and try again."))
            else:
              app.rateGame(release, Verdict(item - 1))

proc infoRow(title, subtitle: string): Widget =
  ## One labelled fact, the standard boxed-list row. A row's title and subtitle
  ## are markup, so catalogue text is escaped rather than shown as entities.
  result = gui:
    ActionRow:
      title = escapeMarkup(title)
      subtitle = escapeMarkup(subtitle)

proc statusRow(title, subtitle: string; tone: CompatibilityTone): Widget =
  ## A fact whose state is carried by a symbolic icon as well as its wording, so
  ## color is never the only signal.
  result = gui:
    ActionRow:
      title = escapeMarkup(title)
      subtitle = escapeMarkup(subtitle)
      case tone
      of tonePositive:
        Icon {.addSuffix.}:
          name = "object-select-symbolic"
          pixelSize = 16
          style = [Success]
      of toneCaution:
        Icon {.addSuffix.}:
          name = "dialog-warning-symbolic"
          pixelSize = 16
          style = [Caution]
      of toneNegative:
        Icon {.addSuffix.}:
          name = "dialog-error-symbolic"
          pixelSize = 16
          style = [Danger]
      else: discard

proc shotButton(app: AppState; path: string; index: int): Widget =
  ## A thumbnail that opens the full-window viewer at its own position. Decoded
  ## small, because a strip only ever shows it small.
  let shot = app.picture(path, 320)
  result = gui:
    Button:
      style = [ButtonFlat]
      tooltip = "View Screenshot"
      if shot.isSome:
        Picture:
          pixbuf = shot.get
          contentFit = ContentCover
          sizeRequest = (272, 153)
      proc clicked() = app.openViewer(index)

proc shotStrip(app: AppState; art: GameArt): Widget =
  ## A strip rather than a wall: the screenshots sit with the banner where they
  ## are seen, and one click opens any of them larger.
  result = gui:
    Box(orient = OrientY, spacing = 10):
      Label {.expand: false, hAlign: AlignStart.}:
        text = "Screenshots"
        xAlign = 0
        style = [LabelHeading]
      ScrolledWindow {.expand: false.}:
        sizeRequest = (-1, 165)
        Box(orient = OrientX, spacing = 10):
          for index in 0..<art.shots.len:
            insert(shotButton(app, art.shots[index], index)) {.expand: false.}

proc ratingsGroup(release: Release; play: Option[Playability];
                  facts: SteamFacts): Widget =
  ## The facts that answer "should I play this": what players and the press say,
  ## and whether it runs here. A row is omitted when its fact is absent, and the
  ## heading names what is actually in the list.
  let summary = compatibilitySummary(release, play, facts)
  let tone = compatibilityTone(release, play, facts)
  let reviews = reviewSummary(facts)
  let critics = criticsSummary(facts)
  let criticsLink = criticsUrl(facts)
  let hasReviews = reviews.len > 0 or critics.len > 0
  let title = if summary.len > 0 and hasReviews: "Runs and reviews"
              elif summary.len > 0: "How it runs on Linux"
              else: "Reviews"
  result = gui:
    PreferencesGroup:
      title = title
      if summary.len > 0:
        insert(statusRow("Linux support", summary, tone))
      if reviews.len > 0:
        insert(infoRow("Player reviews", reviews))
      if critics.len > 0:
        ActionRow:
          title = "Critics"
          subtitle = escapeMarkup(critics)
          if criticsLink.len > 0:
            LinkButton {.addSuffix.}:
              text = "Open"
              uri = criticsLink

proc detailsGroup(facts: SteamFacts): Widget =
  ## Everything secondary: what it costs, when it arrived, who made it, what it
  ## is. An absent fact is never a row.
  let price = priceText(facts)
  let developer = firstOf(facts.developers)
  let released = if facts.releaseDate.isSome: facts.releaseDate.get.value else: ""
  let tags = tagSummary(facts, 6)
  result = gui:
    PreferencesGroup:
      title = "Details"
      if price.len > 0:
        insert(infoRow("Price", price))
      if released.len > 0:
        insert(infoRow("Released", released))
      if developer.len > 0:
        insert(infoRow("Developer", developer))
      if tags.len > 0:
        insert(infoRow("Tags", tags))

proc game(app: AppState): Widget =
  ## The picture is the identity, the ratings are the answer, the screenshots
  ## are the evidence, and the rest is detail.
  let release = app.selected.get
  let art = app.gameArt(release)
  let facts = storeFactsOf(app.catalog.stores, release)
  let play = playabilityOf(app.catalog.play, release)
  let url = steamUrl(release)
  let subtitle = gameSubtitle(facts)
  let blurb = pitch(facts)
  let heroPath = banner(art)
  let hero = if heroPath.isSome: app.picture(heroPath.get, 960)
             else: none(Pixbuf)
  let hasRatings = compatibilitySummary(release, play, facts).len > 0 or
    reviewSummary(facts).len > 0
  let hasDetails = priceText(facts).len > 0 or facts.developers.len > 0 or
    facts.releaseDate.isSome or facts.tags.isSome
  ## A picture's own aspect decides how tall the banner is, so nothing is
  ## stretched and no bars appear; narrower windows crop the sides instead.
  let heroHeight =
    if hero.isSome and height(hero.get) > 0:
      min(max(int(float(ReadingWidth) *
        float(height(hero.get)) / float(width(hero.get))), 200), 560)
    else:
      380
  result = gui:
    ScrolledWindow:
      Clamp:
        maximumSize = ReadingWidth
        Box(orient = OrientY, spacing = 24):
          margin = Margin(top: 24, bottom: 36, left: 18, right: 18)
          if hero.isSome:
            Picture {.expand: false.}:
              pixbuf = hero.get
              contentFit = ContentCover
              sizeRequest = (-1, heroHeight)
          else:
            Box {.expand: false.}:
              orient = OrientY
              sizeRequest = (-1, 120)
              Avatar {.hAlign: AlignCenter, vAlign: AlignCenter.}:
                text = release.title
                size = 96
                showInitials = true
          Box {.expand: false.}:
            orient = OrientY
            spacing = 6
            Label {.expand: false.}:
              text = release.title
              xAlign = 0
              wrap = true
              style = [LabelTitle1]
            if subtitle.len > 0:
              Label {.expand: false.}:
                text = subtitle
                xAlign = 0
                wrap = true
                style = [Dim]
          if url.len > 0:
            Box {.expand: false.}:
              orient = OrientX
              spacing = 12
              Button {.expand: false.}:
                text = "View on Steam"
                style = [ButtonSuggested, ButtonPill]
                proc clicked() = openUri(url)
          if blurb.len > 0:
            Label {.expand: false.}:
              text = blurb
              xAlign = 0
              wrap = true
              style = [Body]
          if hasRatings:
            insert(ratingsGroup(release, play, facts)) {.expand: false.}
          if art.shots.len > 0:
            insert(shotStrip(app, art)) {.expand: false.}
          if release.appid.get(0) > 0:
            insert(ratingRow(app, release)) {.expand: false.}
          if hasDetails:
            insert(detailsGroup(facts)) {.expand: false.}

proc navButton(app: AppState; icon, tooltip, shortcut: string;
               delta: int): Widget =
  ## A large overlaid control: the convention for stepping through pictures in a
  ## GNOME image viewer. Its shortcut is fixed and only ever built once here.
  result = gui:
    Button:
      icon = icon
      tooltip = tooltip
      shortcut = shortcut
      style = [ButtonCircular, Osd]
      margin = 24
      proc clicked() = app.stepViewer(delta)

proc viewer(app: AppState): Widget =
  ## The whole picture on a dark backdrop, with the browse buttons overlaid on
  ## the edges and the position in the header. The file is shown at its own size
  ## and never blown up, so it stays sharp.
  let art = app.gameArt(app.selected.get)
  let items = media(art)
  let index = max(0, min(items.len - 1, app.viewer.get(0)))
  let image = app.picture(items[index], 0)
  result = gui:
    Box(orient = OrientY):
      style = [Osd]
      Overlay:
        if image.isSome:
          Picture:
            pixbuf = image.get
            contentFit = ContentScaleDown
        if items.len > 1:
          insert(navButton(app, "go-previous-symbolic",
            "Previous Picture (Left Arrow)", "<Left>", -1)) {.addOverlay,
              hAlign: AlignStart, vAlign: AlignCenter.}
          insert(navButton(app, "go-next-symbolic",
            "Next Picture (Right Arrow)", "<Right>", 1)) {.addOverlay,
              hAlign: AlignEnd, vAlign: AlignCenter.}

proc chooseCatalog(app: AppState) =
  let (response, state) = app.open: gui:
    FileChooserDialog:
      title = "Open Catalogue"
      action = FileChooserOpen
      DialogButton {.addButton.}:
        text = "Cancel"
        res = DialogCancel
      DialogButton {.addButton.}:
        text = "Open"
        res = DialogAccept
        style = [ButtonSuggested]
  if response.kind == DialogAccept:
    let paths = FileChooserDialogState(state).filenames
    if paths.len > 0:
      let loaded = loadCatalog(catalogPathsFor(paths[0]))
      if loaded.hasGames():
        app.catalog = loaded
        app.pictures.clear()
        app.closeSearch()
      else:
        app.toasts.add(newToast("No games could be read. Choose a Ludex catalogue file and try again."))

proc showDetails(app: AppState) =
  ## Raw diagnostics are available only on request, never above the games.
  discard app.open: gui:
    Dialog:
      title = "Diagnostics"
      defaultSize = (560, 420)
      ScrolledWindow:
        Box(orient = OrientY, spacing = 12, margin = 18):
          for problem in app.catalog.problems:
            Label {.expand: false.}:
              text = problem
              xAlign = 0
              wrap = true
              style = [Caption]
      DialogButton {.addButton.}:
        text = "Close"
        res = DialogClose

proc showAbout(app: AppState) =
  discard app.open: gui:
    AboutWindow:
      applicationName = "Ludex"
      applicationIcon = "applications-games-symbolic"
      developerName = "Ludex contributors"
      version = "0.1.0"
      comments = "Find your next Linux game."
      licenseType = LicenseMIT_X11

when defined(ludexSnapshot):
  proc applyScene(app: AppState)

method view(app: AppState): Widget =
  when defined(ludexSnapshot):
    app.applyScene()
  result = gui:
    AdwWindow:
      defaultSize = initialWindowSize
      ToastOverlay:
        toastQueue = app.toasts
        ToolbarView:
          insert(header(app)) {.addTop.}
          if app.searching and app.selected.isNone:
            insert(searchField(app)) {.addTop.}
          if app.viewer.isSome and app.selected.isSome:
            insert(viewer(app))
          elif app.selected.isSome:
            insert(game(app))
          else:
            insert(collection(app))

when defined(ludexSnapshot):
  var
    sceneDone = false
    sceneAppid = 0
    sceneQuery = ""
    sceneViewer = -1
    sceneCloseViewer = false
    sceneFilters = ""
    sceneColorScheme = ColorSchemeDefault

  proc applyScene(app: AppState) =
    ## Development only: applies the environment's requested scene once, on the
    ## first view, when the state exists and can be mutated directly.
    if sceneDone:
      return
    sceneDone = true
    for name in sceneFilters.split(','):
      case name
      of "runs": app.toggleFilter(fkRunsHere)
      of "deck": app.toggleFilter(fkDeckReady)
      of "unjudged": app.toggleFilter(fkUnjudged)
      of "": discard
      else: app.toggleGenre(name)
    if sceneAppid > 0:
      for item in app.items:
        if item.release.appid.get(0) == sceneAppid:
          app.openGame(item.release)
          break
    if sceneQuery.len > 0:
      app.searching = true
      app.search(sceneQuery)
    if sceneViewer >= 0:
      app.openViewer(sceneViewer)
      if sceneCloseViewer:
        ## Exercises stepping and repeated open/close transitions, which is
        ## where Owlkettle's update path runs over a changing tree.
        discard addGlobalTimeout(250, proc (): bool =
          app.stepViewer(1)
          false)
        discard addGlobalTimeout(400, proc (): bool =
          app.closeViewer()
          false)
        discard addGlobalTimeout(550, proc (): bool =
          app.openViewer(sceneViewer)
          false)

  proc readSceneEnv() =
    ## Development only: reads the scene, size and capture path from the
    ## environment before the window is built.
    sceneAppid = parseInt(getEnv("LUDEX_SNAPSHOT_APPID", "0"))
    sceneQuery = getEnv("LUDEX_SNAPSHOT_QUERY")
    sceneViewer = parseInt(getEnv("LUDEX_SNAPSHOT_VIEWER", "-1"))
    sceneCloseViewer = getEnv("LUDEX_SNAPSHOT_CLOSEVIEWER").len > 0
    sceneFilters = getEnv("LUDEX_SNAPSHOT_FILTER")
    if getEnv("LUDEX_SNAPSHOT_LIGHT").len > 0:
      sceneColorScheme = ColorSchemeForceLight
    let size = getEnv("LUDEX_SNAPSHOT_SIZE")
    if size.len > 0:
      let parts = size.split('x')
      if parts.len == 2:
        initialWindowSize = (parseInt(parts[0]), parseInt(parts[1]))
    let path = getEnv("LUDEX_SNAPSHOT")
    if path.len > 0:
      scheduleCapture(path, parseInt(getEnv("LUDEX_SNAPSHOT_DELAY", "900")),
        hover = getEnv("LUDEX_SNAPSHOT_HOVER").len > 0,
        menu = parseInt(getEnv("LUDEX_SNAPSHOT_MENU", "0")))

when isMainModule:
  let loaded = loadCatalog(defaultPaths())
  when defined(ludexSnapshot):
    readSceneEnv()
    adw.brew(gui(App(catalog = loaded, items = loaded.browse(""))),
      colorScheme = sceneColorScheme,
      stylesheets = @[newStylesheet(GridStyles)])
  else:
    adw.brew(gui(App(catalog = loaded, items = loaded.browse(""))),
      stylesheets = @[newStylesheet(GridStyles)])
