## Development-only window capture.
##
## A GTK window can be rendered to a PNG from its own process: ask the widget
## for a `GtkWidgetPaintable`, snapshot it into a render node, and let the
## window's `GskRenderer` turn that node into a `GdkTexture` this module saves.
## That is the only reliable way to inspect the interface here, where no
## screenshot tool and no working remote display exist.
##
## The whole module is behind `-d:ludexSnapshot`, so the shipping window never
## carries the extra FFI bindings or the timer.

when defined(ludexSnapshot):
  import owlkettle
  import owlkettle/bindings/gtk

  type
    GdkTexture = pointer
    GskRenderNode = pointer
    GskRenderer = pointer

  proc gtk_widget_paintable_new(widget: GtkWidget): pointer {.importc, cdecl.}
  proc gdk_paintable_snapshot(paintable: pointer; snapshot: pointer;
                              width, height: cdouble) {.importc, cdecl.}
  proc gtk_snapshot_new(): pointer {.importc, cdecl.}
  proc gtk_snapshot_free_to_node(snapshot: pointer): GskRenderNode {.importc, cdecl.}
  proc gtk_native_get_renderer(native: GtkWidget): GskRenderer {.importc, cdecl.}
  proc gsk_renderer_render_texture(renderer: GskRenderer; node: GskRenderNode;
                                   region: pointer): GdkTexture {.importc, cdecl.}
  proc gsk_render_node_unref(node: GskRenderNode) {.importc, cdecl.}
  proc gdk_texture_save_to_png(texture: GdkTexture; filename: cstring): cbool
    {.importc, cdecl.}
  proc gtk_widget_get_width(widget: GtkWidget): cint {.importc, cdecl.}
  proc gtk_widget_get_height(widget: GtkWidget): cint {.importc, cdecl.}
  proc gtk_widget_get_css_name(widget: GtkWidget): cstring {.importc, cdecl.}
  proc gtk_widget_set_state_flags(widget: GtkWidget; flags: cuint;
                                  clear: cbool) {.importc, cdecl.}
  proc gtk_widget_get_next_sibling(widget: GtkWidget): GtkWidget {.importc, cdecl.}

  const GtkStateFlagPrelight = 2.cuint
    ## `GTK_STATE_FLAG_PRELIGHT`, the state a pointer hover puts a widget in.

  proc firstToplevel(): GtkWidget =
    let toplevels = gtk_window_get_toplevels()
    if toplevels.isNil:
      return GtkWidget(nil)
    let item = g_list_model_get_item(toplevels, 0)
    if item.isNil:
      return GtkWidget(nil)
    result = GtkWidget(item)

  proc findByCssName(widget: GtkWidget; name: string): GtkWidget =
    var child = gtk_widget_get_first_child(widget)
    while not child.isNil:
      let cssName = gtk_widget_get_css_name(child)
      if not cssName.isNil and $cssName == name:
        return child
      result = findByCssName(child, name)
      if not result.isNil:
        return
      child = gtk_widget_get_next_sibling(child)

  proc collectByCssName(widget: GtkWidget; name: string; found: var seq[GtkWidget]) =
    var child = gtk_widget_get_first_child(widget)
    while not child.isNil:
      let cssName = gtk_widget_get_css_name(child)
      if not cssName.isNil and $cssName == name:
        found.add child
      collectByCssName(child, name, found)
      child = gtk_widget_get_next_sibling(child)

  proc setPrelightDeep(widget: GtkWidget) =
    if widget.isNil:
      return
    gtk_widget_set_state_flags(widget, GtkStateFlagPrelight, cbool(false))
    var child = gtk_widget_get_first_child(widget)
    while not child.isNil:
      setPrelightDeep(child)
      child = gtk_widget_get_next_sibling(child)

  proc hoverFirstGridChild(): bool =
    ## Development only: puts the first `FlowBox` child into the hover state, so
    ## a capture shows exactly what the pointer would. There is no way to move a
    ## pointer from here, and hover styling is otherwise invisible to review.
    let window = firstToplevel()
    if window.isNil:
      return false
    defer: g_object_unref(cast[pointer](window))
    let grid = findByCssName(window, "flowbox")
    if grid.isNil:
      return false
    let child = gtk_widget_get_first_child(grid)
    if child.isNil:
      return false
    setPrelightDeep(child)
    result = true

  proc gtk_menu_button_popup(button: GtkWidget) {.importc, cdecl.}

  var openedPopover: GtkWidget

  proc openMenuButton(index: int): bool =
    ## Development only: pops up one of the header's menus so a capture can show
    ## it. The window has more than one, so the caller names which, and the
    ## popover is taken from that button: the window's first `popover` is not
    ## necessarily the one that was opened.
    let window = firstToplevel()
    if window.isNil:
      return false
    defer: g_object_unref(cast[pointer](window))
    var buttons: seq[GtkWidget]
    collectByCssName(window, "menubutton", buttons)
    if index < 1 or index > buttons.len:
      return false
    let popover = findByCssName(buttons[index - 1], "popover")
    if popover.isNil:
      return false
    openedPopover = popover
    gtk_menu_button_popup(buttons[index - 1])
    result = true

  proc captureWidget(target: GtkWidget; path: string): bool =
    ## Renders one widget to `path`. A popover lives on its own surface, so it
    ## needs its own paintable and renderer; a plain window is captured the same
    ## way, which is what lets one call site serve both.
    if target.isNil:
      return false
    let width = gtk_widget_get_width(target)
    let height = gtk_widget_get_height(target)
    if width <= 0 or height <= 0:
      return false
    let paintable = gtk_widget_paintable_new(target)
    defer: g_object_unref(paintable)
    let snapshot = gtk_snapshot_new()
    gdk_paintable_snapshot(paintable, snapshot,
      cdouble(width), cdouble(height))
    let node = gtk_snapshot_free_to_node(snapshot)
    if node.isNil:
      return false
    defer: gsk_render_node_unref(node)
    var renderer = gtk_native_get_renderer(target)
    if renderer.isNil:
      renderer = gtk_native_get_renderer(firstToplevel())
    if renderer.isNil:
      return false
    let texture = gsk_renderer_render_texture(renderer, node, nil)
    if texture.isNil:
      return false
    defer: g_object_unref(texture)
    result = bool(gdk_texture_save_to_png(texture, path.cstring))

  proc capture(path: string): bool =
    ## Renders the first toplevel to `path`.
    let window = firstToplevel()
    if window.isNil:
      return false
    defer: g_object_unref(cast[pointer](window))
    result = captureWidget(window, path)

  proc capturePopover(path: string): bool =
    ## Renders the open popover, which is not part of the window's own surface.
    let window = firstToplevel()
    if window.isNil:
      return false
    defer: g_object_unref(cast[pointer](window))
    let popover = findByCssName(window, "popover")
    if popover.isNil:
      return false
    result = captureWidget(popover, path)

  proc finish(path: string; menu: int; attempts: int) =
    ## Captures once the window has painted, retrying briefly when the widget is
    ## not yet sized: the first frames after a map can arrive before the content
    ## slot has been laid out, and a capture of a zero-sized widget is no file.
    let saved = if menu > 0 and not openedPopover.isNil:
      captureWidget(openedPopover, path)
    else:
      capture(path)
    if not saved and attempts > 0:
      discard addGlobalTimeout(200, proc (): bool =
        finish(path, menu, attempts - 1)
        false)
      return
    let window = firstToplevel()
    if not window.isNil:
      gtk_window_close(window)
      g_object_unref(cast[pointer](window))

  proc scheduleCapture*(path: string; delayMs: int; hover = false;
                        menu = 0) =
    ## Waits for the first paint, then captures and closes the window so the
    ## process exits and the shell can inspect the PNG. The window's size is
    ## chosen by the caller at construction; GTK has no post-map resize. Any
    ## requested transient state is applied first and given a frame to paint,
    ## and the capture itself waits one more frame so the result is the settled
    ## tree rather than an intermediate one. `menu` selects which header menu to
    ## open, counting from one.
    discard addGlobalTimeout(delayMs, proc (): bool =
      if menu > 0:
        discard openMenuButton(menu)
      if hover:
        discard hoverFirstGridChild()
      discard addGlobalTimeout(300, proc (): bool =
        finish(path, menu, 3)
        false)
      false)
