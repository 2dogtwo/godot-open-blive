extends WebSocketMultiplayerPeer

signal auth_success
signal heartbeat_failed

signal danmaku_received(data)
signal gift_received(data)
signal superchat_added(data)
signal superchat_removed(data)
signal guard_hired(data)

const HEARTBEAT_INTERVAL := 30


class Proto:
	enum Operation {
		OP_HEARTBEAT = 2,
		OP_HEARTBEAT_REPLY = 3,
		OP_SEND_SMS_REPLY = 5,
		OP_AUTH = 7,
		OP_AUTH_REPLY = 8,
	}
	enum Version {
		PLAIN = 0,
		COMPRESSED = 2,
	}
	
	var operation: int # Operation
	var body: PackedByteArray
	
	static func make_heartbeat() -> Proto:
		var proto := Proto.new()
		proto.operation = Operation.OP_HEARTBEAT
		return proto
	
	static func make_auth(auth_body: String) -> Proto:
		var proto := Proto.new()
		proto.operation = Operation.OP_AUTH
		proto.body = auth_body.to_utf8_buffer()
		return proto
	
	static func _unpack(buffer: StreamPeerBuffer, protos: Array) -> int:
		var packet_length := buffer.get_32()
		var header_length := buffer.get_16()
		if header_length != 16:
			push_warning("Invalid header length: %d" % header_length)
			return FAILED
		
		var version := buffer.get_16()
		var operation := buffer.get_32()
		
		buffer.seek(buffer.get_position() + 4)
		
		var raw := buffer.get_data(packet_length - header_length)
		if raw[0]:
			push_warning("Not enough body data")
			return raw[0]
		
		match version:
			Version.PLAIN:
				var proto := Proto.new()
				proto.operation = operation
				proto.body = raw[1]
				protos.append(proto)
			
			Version.COMPRESSED:
				var uncompressed := StreamPeerBuffer.new()
				uncompressed.big_endian = true
				uncompressed.data_array = raw[1].decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP)
				var err := _unpack(uncompressed, protos)
				if err:
					return err
			
			_:
				push_warning("Invalid version: %d" % version)
				return FAILED
		
		return OK
	
	static func unpack(data: PackedByteArray) -> Array: # [Proto]
		var buffer := StreamPeerBuffer.new()
		buffer.big_endian = true
		buffer.data_array = data
		
		var result := []
		_unpack(buffer, result)
		return result
	
	func pack(peer: WebSocketPeer) -> void:
		var buffer := StreamPeerBuffer.new()
		buffer.big_endian = true
		buffer.put_32(16 + body.size())
		buffer.put_16(16)
		buffer.put_16(0)
		buffer.put_32(operation)
		buffer.put_32(0)
		buffer.put_data(body)
		peer.put_packet(buffer.data_array)
	
	func _to_string():
		var index := Operation.values().find(operation)
		if index == -1:
			return "[Proto: %d]" % operation
		return "[Proto: %s]" % Operation.keys()[index]


var _auth_body: String
var _authorized := false
var _last_heartbeat_sent_at := -1
var _last_heartbeat_received_at := -1


func _init():
	connect("connection_established", Callable(self, "_on_ws_connection_established"))
	connect("data_received", Callable(self, "_on_ws_data_received"))


func connect_with_auth(url: String, auth_body: String):
	_auth_body = auth_body
	
	if url.is_empty() or _auth_body.is_empty():
		emit_signal("connection_error")
		return
	
	_authorized = false
	
	var err := create_client(url)
	if err:
		printerr("failed to connect to URL: %s" % url)
		# 不必手动发出 connection_error


func poll_and_heartbeat():
	poll()
	
	var peer := get_peer(1)
	if not peer.is_connected_to_host():
		return
	
	if not _authorized:
		return
	
	var timestamp := Time.get_unix_time_from_system()
	if _last_heartbeat_sent_at + HEARTBEAT_INTERVAL < timestamp:
		Proto.make_heartbeat().pack(peer)
		_last_heartbeat_sent_at = timestamp
	
	if timestamp - _last_heartbeat_received_at > HEARTBEAT_INTERVAL * 3:
		peer.disconnect_from_host()
		emit_signal("heartbeat_failed")


func _on_ws_connection_established(_protocol: String) -> void:
	Proto.make_auth(_auth_body).pack(get_peer(1))


func _on_ws_data_received() -> void:
	for entry in Proto.unpack(get_peer(1).get_packet()):
		var proto: Proto = entry
		match proto.operation:
			Proto.Operation.OP_HEARTBEAT_REPLY:
				# 可以获取当前人气值
#				var buffer := StreamPeerBuffer.new()
#				buffer.big_endian = true
#				buffer.data_array = proto.body
#				print("Popularity: ", buffer.get_32())
				_last_heartbeat_received_at = Time.get_unix_time_from_system()
				
			Proto.Operation.OP_AUTH_REPLY:
				# 如果提供错误的授权数据也并不会返回失败，但无法正常获取数据
				_authorized = true
				_last_heartbeat_sent_at = Time.get_unix_time_from_system()
				_last_heartbeat_received_at = Time.get_unix_time_from_system()
				emit_signal("auth_success")
			
			Proto.Operation.OP_SEND_SMS_REPLY:
				var test_json_conv = JSON.new()
				test_json_conv.parse(proto.body.get_string_from_utf8())
				var body: Dictionary = test_json_conv.get_data()
				var command: String = body.get("cmd")
				match command:
					"LIVE_OPEN_PLATFORM_DM":
						emit_signal("danmaku_received", body.data)
					
					"LIVE_OPEN_PLATFORM_SEND_GIFT":
						emit_signal("gift_received", body.data)
					
					"LIVE_OPEN_PLATFORM_SUPER_CHAT":
						emit_signal("superchat_added", body.data)
					
					"LIVE_OPEN_PLATFORM_SUPER_CHAT_DEL":
						emit_signal("superchat_removed", body.data)
					
					"LIVE_OPEN_PLATFORM_GUARD":
						emit_signal("guard_hired", body.data)
			
			_:
				push_warning("Unknown operation: %d" % proto.operation)
