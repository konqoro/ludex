## A quiet, artwork-first answer to “what should I play next?”.
##
## One automatically ordered collection leads to one game. The window never
## pretends catalogue entries are installed games: its handoff is View on Steam.
## FlowBox supplies native adaptive columns; bounded pages keep image decoding
## and widget work independent of catalogue size. Search still covers every game.
## Catalog owns disk data, present owns wording, and this module owns interaction.

import std/[options, strutils, tables]

import owlkettle
import owlkettle/adw

import ludexcore/[models, query, taste]
import ludexui/[catalog, present, widgets]
when defined(ludexSnapshot):
  import std/os
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

const GridStyles = """
.ludex-hero { border-radius: 12px 12px 0 0; }
.ludex-shot { padding: 0; border-radius: 9px; }
button.ludex-store { background: @accent_bg_color; color: @accent_fg_color; }
button.ludex-store:hover { filter: brightness(1.1); }
button.ludex-store label { text-decoration: none; }
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

var initialWindowSize = (1000, 720)
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

proc resetBrowse(app: AppState) =
  app.page = 0
  app.galleryScroll.reset()
  app.refreshItems()

proc search(app: AppState; text: string) =
  app.query = text
  app.resetBrowse()

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
  var active: seq[string]
  if filters.runsHere: active.add "Runs on Linux"
  if filters.deckReady: active.add "Steam Deck ready"
  if filters.unjudged: active.add "Hide games I’ve rated"
  if filters.genres.len > 0: active.add filters.genres.join(" or ")
  if active.len == 0: "Filter Games"
  else: "Filter Games: " & active.join(" · ")

proc clearFilters(app: AppState) =
  app.filters = Filters()
  app.resetBrowse()

proc toggleFilter(app: AppState; kind: FilterKind) =
  case kind
  of fkRunsHere: app.filters.runsHere = not app.filters.runsHere
  of fkDeckReady: app.filters.deckReady = not app.filters.deckReady
  of fkUnjudged: app.filters.unjudged = not app.filters.unjudged
  app.resetBrowse()

proc toggleGenre(app: AppState; genre: string) =
  let index = app.filters.genres.find(genre)
  if index >= 0:
    app.filters.genres.delete(index)
  else:
    app.filters.genres.add genre
  app.resetBrowse()

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

proc gameArt(app: AppState; release: Release): ArtFiles =
  app.catalog.artFiles(release.appid.get(0))

func banner(art: ArtFiles): Option[string] =
  # Prefer page art; the store header is only 460×215.
  if art.background.isSome:
    result = art.background
  elif art.header.isSome:
    result = art.header
  elif art.shots.len > 0:
    result = some art.shots[0]

proc openViewer(app: AppState; index: int) =
  app.viewer = some index

proc closeViewer(app: AppState) =
  app.viewer = none(int)

proc stepViewer(app: AppState; delta: int) =
  ## Moving past either end stays put rather than wrapping.
  if app.selected.isNone or app.viewer.isNone:
    return
  let count = app.gameArt(app.selected.get).shots.len
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
  # The primary menu contains app-wide actions; filters have their own menu.
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
  # A labeled library control; check-role items keep it open for multiple choices.
  let genres = app.catalog.genreOptions()
  result = gui:
    MenuButton:
      tooltip = filterTooltip(app.filters)
      style = [ButtonFlat]
      Box(orient = OrientX, spacing = 6):
        Label:
          text = if filtersActive(app.filters): "Filters (" & $filterCount(app.filters) & ")"
                 else: "Filters"
        Icon {.expand: false.}:
          name = "pan-down-symbolic"
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
  let count = app.gameArt(app.selected.get).shots.len
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
        title = if app.selected.isNone and app.searching: "Search Results"
                else: app.viewerTitle()
        subtitle = if app.selected.isNone and app.catalog.hasGames():
                     $app.items.len & " games"
                   else: ""
      if app.selected.isSome:
        insert(backButton(app)) {.addLeft.}
      else:
        insert(searchToggle(app)) {.addLeft.}
        if app.catalog.hasGames():
          insert(filterMenu(app)) {.addLeft.}
          if filtersActive(app.filters):
            Button {.addLeft.}:
              icon = "edit-clear-symbolic"
              tooltip = "Clear Filters"
              style = [ButtonFlat]
              proc clicked() = app.clearFilters()
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
          style = [ButtonPill]
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
          style = [ButtonPill]
          proc clicked() = app.clearFilters()

const LibraryStyles = """
button.ludex-tile { padding: 12px; }
"""

proc gameTile(app: AppState; item: BrowseItem): Widget =
  let release = item.release
  let files = app.catalog.artFiles(release.appid.get(0))
  let art = if files.header.isSome: app.picture(files.header.get, 220)
            else: none(Pixbuf)
  let genres = gameGenres(storeFactsOf(app.catalog.stores, release))
  let loved = app.catalog.taste.verdictOf(release.appid.get(0)) == some vLoved
  result = gui:
    Button:
      style = [BoxCard, StyleClass("ludex-tile")]
      tooltip = release.title
      Box(orient = OrientY, spacing = 12):
        sizeRequest = (220, -1)
        if art.isSome:
          Picture {.expand: false.}:
            pixbuf = art.get
            contentFit = ContentCover
            sizeRequest = (220, 120)
        else:
          Box {.expand: false.}:
            orient = OrientY
            sizeRequest = (220, 120)
            Avatar {.hAlign: AlignCenter, vAlign: AlignCenter.}:
              text = release.title
              size = 64
              showInitials = true
        Box {.expand: false.}:
          orient = OrientY
          spacing = 4
          Box {.expand: false.}:
            orient = OrientX
            spacing = 6
            BoundedLabel:
              text = release.title
              xAlign = 0
              maxChars = 22
              ellipsize = EllipsizeEnd
              style = [StyleClass("heading")]
            if loved:
              Icon {.expand: false, vAlign: AlignCenter.}:
                name = "starred-symbolic"
                pixelSize = 16
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
      margin = Margin(top: 6, bottom: 6)
      Button {.expand: false.}:
        icon = "go-previous-symbolic"
        style = [ButtonCircular]
        tooltip = "Previous Games"
        sensitive = app.page > 0
        proc clicked() =
          dec app.page
          app.galleryScroll.reset()
      Label {.expand: false.}:
        text = $(app.page + 1) & " / " & $pages
        style = [Dim]
      Button {.expand: false.}:
        icon = "go-next-symbolic"
        style = [ButtonCircular]
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
        Box(orient = OrientY, spacing = 24):
          margin = Margin(top: 18, bottom: 30, left: 18, right: 18)
          FlowBox {.expand: false.}:
            style = [Grid]
            columns = 1..4
            homogeneous = true
            rowSpacing = 18
            columnSpacing = 18
            selectionMode = SelectionNone
            for index in first..<last:
              insert(gameTile(app, app.items[index]))
          if app.items.len > PageSize:
            insert(pagination(app)) {.expand: false, hAlign: AlignCenter.}

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
      ComboRow:
        title = "Your rating"
        subtitle = "Shape future suggestions"
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
  # Wording and an icon carry the status independently of color.
  let indicator = case tone
    of tonePositive: ("object-select-symbolic", Success)
    of toneCaution: ("dialog-warning-symbolic", Caution)
    of toneNegative: ("dialog-error-symbolic", Danger)
    else: ("", Dim)
  result = gui:
    ActionRow:
      title = escapeMarkup(title)
      subtitle = escapeMarkup(subtitle)
      if indicator[0].len > 0:
        Icon {.addSuffix.}:
          name = indicator[0]
          pixelSize = 16
          style = [indicator[1]]

proc shotButton(app: AppState; path: string; index: int): Widget =
  ## A thumbnail that opens the full-window viewer at its own position. Decoded
  ## small, because a strip only ever shows it small.
  let shot = app.picture(path, 320)
  result = gui:
    Button:
      tooltip = "View Screenshot " & $(index + 1)
      style = [ButtonFlat, StyleClass("ludex-shot")]
      if shot.isSome:
        Picture:
          pixbuf = shot.get
          contentFit = ContentCover
          sizeRequest = (272, 153)
      else:
        Icon:
          name = "image-missing-symbolic"
          sizeRequest = (272, 153)
      proc clicked() = app.openViewer(index)

proc shotStrip(app: AppState; art: ArtFiles): Widget =
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
  ## Artwork, identity and the store action share one native card.
  ## A single clamp keeps the header and supporting information aligned.
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
    reviewSummary(facts).len > 0 or criticsSummary(facts).len > 0
  let hasDetails = priceText(facts).len > 0 or firstOf(facts.developers).len > 0 or
    (facts.releaseDate.isSome and facts.releaseDate.get.value.len > 0) or
    tagSummary(facts, 6).len > 0
  result = gui:
    ScrolledWindow:
      Clamp:
        maximumSize = 820
        Box(orient = OrientY, spacing = 24):
          margin = Margin(top: 12, bottom: 36, left: 18, right: 18)
          Box {.expand: false.}:
            orient = OrientY
            style = [BoxCard]
            if hero.isSome:
              Picture {.expand: false.}:
                pixbuf = hero.get
                contentFit = ContentCover
                sizeRequest = (-1, 220)
                style = [StyleClass("ludex-hero")]
            Box {.expand: false.}:
              orient = OrientY
              spacing = 16
              margin = 24
              if hero.isNone:
                Avatar {.expand: false, hAlign: AlignStart.}:
                  text = release.title
                  size = 64
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
                LinkButton {.expand: false, hAlign: AlignStart.}:
                  text = "View on Steam"
                  uri = url
                  style = [ButtonSuggested, ButtonPill, StyleClass("ludex-store")]
          if blurb.len > 0:
            Label {.expand: false.}:
              text = blurb
              xAlign = 0
              wrap = true
              margin = Margin(left: 12, right: 12)
              style = [Body]
          if hasRatings:
            insert(ratingsGroup(release, play, facts)) {.expand: false.}
          if release.appid.get(0) > 0:
            insert(ratingRow(app, release)) {.expand: false.}
          if art.shots.len > 0:
            insert(shotStrip(app, art)) {.expand: false.}
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
      margin = 12
      sensitive = if delta < 0: app.viewer.get(0) > 0
                  else: app.viewer.get(0) + 1 < app.gameArt(app.selected.get).shots.len
      proc clicked() = app.stepViewer(delta)

proc viewer(app: AppState): Widget =
  ## The whole picture on a dark backdrop, with the browse buttons overlaid on
  ## the edges and the position in the header. The file is shown at its own size
  ## and never blown up, so it stays sharp.
  let art = app.gameArt(app.selected.get)
  let items = art.shots
  let index = max(0, min(items.len - 1, app.viewer.get(0)))
  if items.len == 0:
    return gui:
      StatusPage:
        iconName = "image-missing-symbolic"
        title = "No Screenshots"
  let image = app.picture(items[index], 0)
  result = gui:
    Box(orient = OrientY):
      style = [Osd]
      Overlay:
        if image.isSome:
          Picture:
            pixbuf = image.get
            contentFit = ContentScaleDown
        else:
          StatusPage:
            iconName = "image-missing-symbolic"
            title = "Picture Unavailable"
            description = "This screenshot could not be read."
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
        Clamp:
          maximumSize = 560
          Box(orient = OrientY, spacing = 18, margin = 24):
            for problem in app.catalog.problems:
              Label {.expand: false.}:
                text = problem
                xAlign = 0
                wrap = true
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
    let dialog = getEnv("LUDEX_SNAPSHOT_DIALOG")
    if dialog.len > 0:
      discard addGlobalTimeout(400, proc (): bool =
        case dialog
        of "about": app.showAbout()
        of "diagnostics": app.showDetails()
        of "open": app.chooseCatalog()
        else: discard
        false)
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
    if getEnv("LUDEX_SNAPSHOT_FIRST").len > 0 and app.items.len > 0:
      app.openGame(app.items[0].release)
    if sceneViewer >= 0:
      app.openViewer(sceneViewer)
      if sceneCloseViewer:
        ## Exercises stepping and repeated open/close transitions, which is
        ## where Owlkettle's update path runs over a changing tree.
        discard addGlobalTimeout(250, proc (): bool =
          app.stepViewer(1)
          discard app.redraw()
          false)
        discard addGlobalTimeout(400, proc (): bool =
          app.closeViewer()
          discard app.redraw()
          false)
        discard addGlobalTimeout(550, proc (): bool =
          app.openViewer(sceneViewer)
          discard app.redraw()
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
  when defined(ludexSnapshot):
    let path = getEnv("LUDEX_SNAPSHOT_CATALOG", "data/releases.jsonl")
    let loaded = loadCatalog(catalogPathsFor(path))
    readSceneEnv()
    adw.brew(gui(App(catalog = loaded, items = loaded.browse(""))),
      colorScheme = sceneColorScheme,
      stylesheets = @[newStylesheet(GridStyles & LibraryStyles)])
  else:
    let loaded = loadCatalog(defaultPaths())
    adw.brew(gui(App(catalog = loaded, items = loaded.browse(""))),
      stylesheets = @[newStylesheet(GridStyles & LibraryStyles)])
