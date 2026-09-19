## Small native interaction bridges missing from Owlkettle's public widgets.
## Search takes focus when mapped; collection scrolling survives a detail visit.
## Adjustment signals deliberately avoid redraws while the user scrolls.

import owlkettle
import owlkettle/bindings/gtk

proc gtk_adjustment_get_value(adjustment: GtkAdjustment): cdouble {.importc, cdecl.}
proc gtk_adjustment_get_upper(adjustment: GtkAdjustment): cdouble {.importc, cdecl.}
proc gtk_adjustment_get_page_size(adjustment: GtkAdjustment): cdouble {.importc, cdecl.}
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
  position: float
  generation: int

proc newScrollMemory*(): ScrollMemory =
  ## Keep one memory in application state for each independently scrolled view.
  ScrollMemory()

proc reset*(memory: ScrollMemory) =
  ## New search results or a new page begin at the top.
  memory.position = 0
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
  memory: ScrollMemory
  adjustment {.private, onlyState.}: GtkAdjustment
  changedHandler {.private, onlyState.}: culong
  valueHandler {.private, onlyState.}: culong
  generation {.private, onlyState.}: int
  restoring {.private, onlyState.}: bool

  hooks:
    beforeBuild:
      state.internalWidget = gtk_scrolled_window_new(nil.GtkAdjustment, nil.GtkAdjustment)
    afterBuild:
      state.adjustment = gtk_scrolled_window_get_vadjustment(state.internalWidget)
      state.generation = state.memory.generation
      state.restoring = true
      proc changed(adjustment: GtkAdjustment; data: pointer) {.cdecl.} =
        let state = cast[ptr RememberedScrollStateObj](data)
        if state.restoring and gtk_adjustment_get_upper(adjustment) > 0:
          let position = min(state.memory.position,
            max(0.0, gtk_adjustment_get_upper(adjustment) -
              gtk_adjustment_get_page_size(adjustment)))
          gtk_adjustment_set_value(adjustment, position)
          state.restoring = false
      proc valueChanged(adjustment: GtkAdjustment; data: pointer) {.cdecl.} =
        let state = cast[ptr RememberedScrollStateObj](data)
        if not state.restoring and state.generation == state.memory.generation:
          state.memory.position = gtk_adjustment_get_value(adjustment)
      state.changedHandler = g_signal_connect(pointer(state.adjustment), "changed",
        changed, addr state[])
      state.valueHandler = g_signal_connect(pointer(state.adjustment), "value-changed",
        valueChanged, addr state[])
    update:
      if state.generation != state.memory.generation:
        state.generation = state.memory.generation
        gtk_adjustment_set_value(state.adjustment, 0)
    destroy:
      if state.changedHandler != 0:
        g_signal_handler_disconnect(pointer(state.adjustment), state.changedHandler)
        g_signal_handler_disconnect(pointer(state.adjustment), state.valueHandler)
