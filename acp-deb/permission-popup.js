// permission window, reads the request as json from stdin and prints the chosen option id
// closing the window without a choice prints nothing
// gtk 3 on x11 on purpose: wayland has no way to stay above other windows

import Gdk from "gi://Gdk?version=3.0";
import Gio from "gi://Gio";
import GioUnix from "gi://GioUnix";
import GLib from "gi://GLib";
import Gtk from "gi://Gtk?version=3.0";
import System from "system";

// node passes stdin as a socket, which /dev/stdin cannot open
const stdin = new GioUnix.InputStream({ fd: 0, close_fd: false });
const received = Gio.MemoryOutputStream.new_resizable();
received.splice(stdin, Gio.OutputStreamSpliceFlags.CLOSE_TARGET, null);
const request = JSON.parse(new TextDecoder().decode(received.steal_as_bytes().toArray()));

const STYLES = { allow_once: "suggested-action", reject_once: "destructive-action" };

function buildWindow(app) {
  Gtk.Settings.get_default().gtk_application_prefer_dark_theme = true;

  const window = new Gtk.ApplicationWindow({
    application: app,
    title: `${request.project}: Berechtigung`,
    default_width: 860,
    default_height: 560,
    type_hint: Gdk.WindowTypeHint.DIALOG,
    focus_on_map: false,
  });
  window.set_keep_above(true);
  window.stick();
  window.set_titlebar(new Gtk.HeaderBar({ show_close_button: true, title: window.title }));

  const title = new Gtk.Label({ use_markup: true, wrap: true, xalign: 0, selectable: true });
  title.set_markup(`<big><b>${GLib.markup_escape_text(request.title, -1)}</b></big>`);

  const detail = new Gtk.TextView({
    editable: false,
    cursor_visible: false,
    monospace: true,
    wrap_mode: Gtk.WrapMode.WORD_CHAR,
    top_margin: 12,
    bottom_margin: 12,
    left_margin: 12,
    right_margin: 12,
  });
  detail.get_buffer().set_text(request.detail, -1);

  const scrolled = new Gtk.ScrolledWindow({ vexpand: true });
  scrolled.add(detail);
  const frame = new Gtk.Frame();
  frame.add(scrolled);

  const buttons = new Gtk.Box({ spacing: 8, halign: Gtk.Align.END });
  for (const option of request.options) {
    const button = new Gtk.Button({ label: option.name, can_focus: false });
    if (STYLES[option.kind]) button.get_style_context().add_class(STYLES[option.kind]);
    button.connect("clicked", () => {
      print(option.optionId);
      app.quit();
    });
    buttons.add(button);
  }

  const content = new Gtk.Box({
    orientation: Gtk.Orientation.VERTICAL,
    spacing: 12,
    margin_top: 12,
    margin_bottom: 12,
    margin_start: 12,
    margin_end: 12,
  });
  content.add(title);
  content.add(frame);
  content.add(buttons);
  window.add(content);

  window.connect("key-press-event", (_window, event) => {
    if (event.get_keyval()[1] !== Gdk.KEY_Escape) return false;
    app.quit();
    return true;
  });

  return window;
}

const app = new Gtk.Application({
  application_id: "dev.xi72yow.AcpNotify",
  flags: Gio.ApplicationFlags.NON_UNIQUE,
});
app.connect("activate", () => buildWindow(app).show_all());
System.exit(app.run([]));
