@tool
extends EditorPlugin

## Adds "Push to Voice Partner" to the Dialogic timeline event context menu.
## The selected voice event (and its paired text event) is sent to the local
## Voice Partner service; the target project is the one the app has active.

const PUSH_ITEM_ID := 100
const FIX_ITEM_ID := 101
const SERVICE_URL := "http://127.0.0.1:3900"
const SETTING_URL := "voice_partner/server_url"
const MAX_ATTACH_FRAMES := 600

var _popup: PopupMenu
var _visual_editor: Node
var _http: HTTPRequest
var _pending := 0
var _frames := 0
var _pending_inserts: Array = []
var _created_voice_nodes: Array = []


func _enter_tree() -> void:
	_ensure_settings()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	set_process(true)


func _ensure_settings() -> void:
	if not Engine.is_editor_hint():
		return
	var settings := EditorInterface.get_editor_settings()
	if not settings.has_setting(SETTING_URL):
		settings.set_setting(SETTING_URL, SERVICE_URL)


func _service_url() -> String:
	var url := SERVICE_URL
	if Engine.is_editor_hint():
		var settings := EditorInterface.get_editor_settings()
		if settings.has_setting(SETTING_URL):
			var configured := str(settings.get_setting(SETTING_URL)).strip_edges()
			if not configured.is_empty():
				url = configured
	return url.trim_suffix("/")


func _process(_delta: float) -> void:
	if _popup != null:
		set_process(false)
		return
	if _frames >= MAX_ATTACH_FRAMES:
		set_process(false)
		return
	_frames += 1
	_try_attach()


func _try_attach() -> void:
	var plugin: Node = DialogicUtil.get_dialogic_plugin()
	if plugin == null:
		return
	var editor_view: Control = plugin.get("editor_view")
	if editor_view == null:
		return
	_visual_editor = editor_view.find_child("VisualEditor", true, false)
	var popup := editor_view.find_child("EventPopupMenu", true, false) as PopupMenu
	if popup == null:
		return

	_popup = popup
	if popup.get_item_index(PUSH_ITEM_ID) == -1:
		popup.add_separator()
		popup.add_item("Push to Voice Partner", PUSH_ITEM_ID)
		popup.add_item("Fix duplicate / invalid UUIDs", FIX_ITEM_ID)
	if not popup.id_pressed.is_connected(_on_popup_id_pressed):
		popup.id_pressed.connect(_on_popup_id_pressed)


func _on_popup_id_pressed(id: int) -> void:
	if id == FIX_ITEM_ID:
		_fix_uuids()
		return
	if id != PUSH_ITEM_ID or _popup == null:
		return
	var clicked: Node = _popup.get("current_event")
	if clicked == null:
		return

	var nodes: Array = []
	if _visual_editor != null:
		var selected: Variant = _visual_editor.get("selected_items")
		if selected is Array and selected.has(clicked):
			nodes = selected.duplicate()
	if nodes.is_empty():
		nodes = [clicked]

	_pending_inserts.clear()
	var lines: Array = []
	var seen := {}
	for node in nodes:
		if not (node is Node) or not node.is_inside_tree():
			continue
		var line := _line_for_node(node)
		if line.is_empty():
			continue
		if seen.has(line.uuid):
			continue
		seen[line.uuid] = true
		lines.append(line)

	if not _pending_inserts.is_empty():
		_insert_pending_voices()

	if lines.is_empty():
		return
	_save_timeline()
	_push(lines)


func _fix_uuids() -> void:
	if _visual_editor == null:
		return
	var timeline := _visual_editor.find_child("Timeline", true, false)
	if timeline == null:
		_toast("Voice Partner: timeline container not found.")
		return

	var seen := {}
	var fixed := 0
	for child in timeline.get_children():
		var resource: Variant = child.get("resource")
		if not (resource is DialogicVoiceEvent):
			continue
		if not ("uuid" in resource):
			continue
		var uuid := str(resource.get("uuid"))
		if not _is_valid_uuid(uuid) or seen.has(uuid):
			uuid = DialogicVoiceEvent._new_uuid()
			resource.set("uuid", uuid)
			fixed += 1
		seen[uuid] = true

	if fixed == 0:
		_toast("Voice Partner: all voice UUIDs are valid.")
		return
	_save_timeline()
	_reload_visual_editor()
	_toast("Voice Partner: fixed %d UUID(s)." % fixed)


func _reload_visual_editor() -> void:
	if _visual_editor == null:
		return
	var timeline_editor: Variant = _visual_editor.get("timeline_editor")
	if timeline_editor == null:
		return
	var resource: Variant = timeline_editor.get("current_resource")
	if resource != null and _visual_editor.has_method("load_timeline"):
		_visual_editor.call("load_timeline", resource)


func _is_valid_uuid(value: String) -> bool:
	return value.length() >= 8 and value != "<null>" and value != "null"


func _line_for_node(node: Node) -> Dictionary:
	var resource: Variant = node.get("resource")
	if resource == null:
		return {}

	if resource is DialogicVoiceEvent:
		var voice_event: DialogicVoiceEvent = resource
		if not ("uuid" in voice_event):
			_toast("Voice Partner: the voice event has no uuid field (Dialogic build without the patch).")
			return {}
		var uuid := str(voice_event.get("uuid"))
		if not _is_valid_uuid(uuid):
			voice_event.set("uuid", DialogicVoiceEvent._new_uuid())
		return _line_from_pair(voice_event, _text_after(node))

	if resource is DialogicTextEvent:
		var text_event: DialogicTextEvent = resource
		var voice: DialogicVoiceEvent = _voice_before(node)
		if voice == null:
			voice = _new_voice_for(node)
		if voice == null:
			return {}
		if not ("uuid" in voice):
			_toast("Voice Partner: the existing voice event has no uuid field. Restart the editor so Dialogic reloads the patched event script.")
			return {}
		var voice_uuid := str(voice.get("uuid"))
		if not _is_valid_uuid(voice_uuid):
			voice.set("uuid", DialogicVoiceEvent._new_uuid())
		return _line_from_pair(voice, text_event)

	return {}


func _text_after(node: Node) -> DialogicTextEvent:
	var parent := node.get_parent()
	var index := node.get_index()
	if index + 1 < parent.get_child_count():
		var next: Node = parent.get_child(index + 1)
		if next.get("resource") is DialogicTextEvent:
			return next.get("resource")
	return null


func _voice_before(node: Node) -> DialogicVoiceEvent:
	var parent := node.get_parent()
	var index := node.get_index()
	if index > 0:
		var previous: Node = parent.get_child(index - 1)
		if previous.get("resource") is DialogicVoiceEvent:
			return previous.get("resource")
	return null


func _new_voice_for(text_node: Node) -> DialogicVoiceEvent:
	var voice := DialogicVoiceEvent.new()
	voice.uuid = DialogicVoiceEvent._new_uuid()
	_pending_inserts.append([voice, text_node])
	return voice


func _insert_pending_voices() -> void:
	var pairs := _pending_inserts.duplicate()
	_pending_inserts.clear()

	var undo: UndoRedo = _visual_editor.get("TimelineUndoRedo")
	if undo == null:
		for pair in pairs:
			_visual_editor.call("add_event_node", pair[0], pair[1].get_index())
		return

	undo.create_action("Voice Partner: add %d voice event(s)." % pairs.size())
	undo.add_do_method(_do_insert_voices.bind(pairs))
	undo.add_undo_method(_undo_insert_voices)
	undo.commit_action()
	_toast("Voice Partner: created %d voice event(s)." % pairs.size())


func _do_insert_voices(pairs: Array) -> void:
	_created_voice_nodes.clear()
	var ordered := pairs.duplicate()
	ordered.sort_custom(
		func(a: Array, b: Array) -> bool: return a[1].get_index() > b[1].get_index()
	)
	for pair in ordered:
		var voice: DialogicVoiceEvent = pair[0]
		var text_node: Node = pair[1]
		if not is_instance_valid(text_node):
			continue
		var block: Variant = _visual_editor.call(
			"add_event_node", voice, text_node.get_index(), false, true
		)
		if block != null:
			_created_voice_nodes.append(block)


func _undo_insert_voices() -> void:
	var indexes: Array = []
	for node in _created_voice_nodes:
		if is_instance_valid(node) and node.is_inside_tree():
			indexes.append(node.get_index())
	_created_voice_nodes.clear()
	if indexes.is_empty():
		return

	indexes.sort()
	var indexed := {}
	for index in indexes:
		indexed[index] = true
	_visual_editor.call("delete_events_indexed", indexed)


func _line_from_pair(voice: DialogicVoiceEvent, text_event: DialogicTextEvent) -> Dictionary:
	var uuid := str(voice.get("uuid"))
	if not _is_valid_uuid(uuid):
		uuid = DialogicVoiceEvent._new_uuid()
		voice.set("uuid", uuid)

	var text := ""
	var character := ""
	var character_name := ""
	if text_event != null:
		text = text_event.text
		character = text_event.character_identifier
		if text_event.character:
			character_name = text_event.character.display_name
	return {
		"uuid": uuid,
		"character": character,
		"character_name": character_name,
		"text": text,
	}


func _save_timeline() -> void:
	if _visual_editor == null:
		return
	if _visual_editor.has_method("something_changed"):
		_visual_editor.something_changed()
	if _visual_editor.has_method("save_timeline"):
		_visual_editor.save_timeline()


func _push(lines: Array) -> void:
	var dtl := str(DialogicUtil.get_editor_setting("current_timeline_path", ""))
	if dtl.is_empty():
		_toast("Voice Partner: open a timeline first.")
		return

	var payload := {"dtl": dtl, "lines": lines}
	for line in lines:
		print("[Voice Partner] line: ", line.get("uuid"), " | ", line.get("character"), " | ", line.get("text"))
	var error := _http.request(
		_service_url() + "/sync/lines",
		["Content-Type: application/json"],
		HTTPClient.METHOD_POST,
		JSON.stringify(payload)
	)
	if error != OK:
		_toast("Voice Partner: could not start the request (%d)." % error)
		return

	_pending = lines.size()
	_toast("Voice Partner: pushing %d line(s)..." % lines.size())


func _on_request_completed(
	result: int,
	response_code: int,
	_headers: PackedStringArray,
	body: PackedByteArray
) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_toast("Voice Partner: service unreachable (result %d)." % result)
		return
	if response_code != 200:
		_toast("Voice Partner: HTTP %d: %s" % [response_code, body.get_string_from_utf8()])
		return

	var parsed: Variant = JSON.parse_string(body.get_string_from_utf8())
	if typeof(parsed) == TYPE_DICTIONARY:
		var data: Dictionary = parsed
		_toast("Voice Partner: %d pushed (%d created, %d updated, section %s)." % [
			_pending,
			int(data.get("created", 0)),
			int(data.get("updated", 0)),
			str(data.get("section", "?")),
		])
	else:
		_toast("Voice Partner: %d line(s) pushed." % _pending)


func _toast(text: String) -> void:
	print("[Voice Partner] ", text)
	var toaster: Variant = EditorInterface.call("get_editor_toaster")
	if toaster != null:
		toaster.call("push_toast", text)
