## Small native interaction bridges missing from Owlkettle's public widgets.
## Search takes focus when mapped; a changed collection starts at the top;
## a page can answer one key without spending a visible control on it.

import owlkettle
import owlkettle/bindings/gtk

proc gtk_label_set_max_width_chars(label: GtkWidget; chars: cint)
  {.importc, cdecl.}

renderable BoundedLabel of Label:
  ## A label whose natural width stops at `maxChars`. A `FlowBox` sizes its
  ## cells from the widest child, so one long title would otherwise push every
  ## tile in the grid to the same oversized width.
  maxChars: int = 24

  hooks:
    beforeBuild:
      state.internalWidget = gtk_label_new("")
    afterBuild:
      if state.maxChars > 0:
        gtk_label_set_max_width_chars(state.internalWidget, state.maxChars.cint)

renderable CheckedMenuItem of ModelButton:
  ## A menu row with a checkmark that keeps its label. Owlkettle's
  ## `ModelButton.icon` sets GTK's `iconic`, which replaces the label with the
  ## picture, so the checkmark has to come from GTK's own indicator instead:
  ## role `check` plus `active`. A check-role row also keeps its popover open
  ## when clicked, which is what a set of independent filters needs.
  active: bool

  hooks:
    beforeBuild:
      state.internalWidget = GtkWidget(g_object_new(
        g_type_from_name("GtkModelButton"), "role", cint(1), nil))
  hooks active:
    property:
      var value = g_value_new(state.active)
      g_object_set_property(state.internalWidget.pointer, "active", value.addr)
      g_value_unset(value.addr)

type ScrollMemory* = ref object
  ## Tracks when a view's content changes so it can start at the top again. The
  ## collection is never unmounted while browsing, so GTK already restores its
  ## own scroll offset on return; only a new search, filter or page needs a
  ## reset. Keeping no offset here is what avoids depending on the adjustment
  ## `upper` before the first layout pass.
  generation: int

proc newScrollMemory*(): ScrollMemory =
  ## Keep one memory in application state for each independently scrolled view.
  ScrollMemory()

proc reset*(memory: ScrollMemory) =
  ## New search results or a new page begin at the top.
  inc memory.generation

renderable FocusSearchEntry of SearchEntry:
  mapHandler {.private, onlyState.}: culong

  hooks:
    beforeBuild:
      state.internalWidget = gtk_search_entry_new()
    afterBuild:
      proc mapped(widget: GtkWidget; data: pointer) {.cdecl.} =
        gtk_widget_grab_focus(widget)
      state.mapHandler = g_signal_connect(state.internalWidget, "map", mapped, nil)
    destroy:
      if state.mapHandler != 0:
        g_signal_handler_disconnect(pointer(state.internalWidget), state.mapHandler)

renderable RememberedScroll of ScrolledWindow:
  ## A ScrolledWindow that jumps back to the top when its `memory` generation
  ## changes. It keeps no offset deliberately: the collection stays mounted
  ## under the game and viewer pages, so GTK restores its position on return.
  memory: ScrollMemory
  generation {.private, onlyState.}: int

  hooks:
    beforeBuild:
      state.internalWidget = gtk_scrolled_window_new(nil.GtkAdjustment, nil.GtkAdjustment)
    afterBuild:
      state.generation = state.memory.generation
    update:
      if state.generation != state.memory.generation:
        state.generation = state.memory.generation
        gtk_adjustment_set_value(
          gtk_scrolled_window_get_vadjustment(state.internalWidget), 0)

renderable KeyShortcut of Button:
  ## A `Button` that exists only to carry a keyboard shortcut. Owlkettle's own
  ## `Button.shortcut` installs the window-managed controller and `clicked` is
  ## the callback, so this renderable adds no GTK code of its own; it hides its
  ## button in `afterBuild` so no visible control appears. A hidden widget stays
  ## rooted, and a managed shortcut controller is registered with the window's
  ## shortcut manager, so the key still fires.
  hooks:
    beforeBuild:
      state.internalWidget = gtk_button_new()
    afterBuild:
      gtk_widget_hide(state.internalWidget)
