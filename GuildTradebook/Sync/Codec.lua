--[[
Message encoding: Lua table -> CBOR -> Deflate -> Base64, all native
C_EncodingUtil. Base64 keeps the payload free of NUL and of AceComm's control
bytes. Decoding treats input as untrusted: sizes are capped and every step is
wrapped in pcall. Shape validation happens in Store / Protocol.
]]
local _, ns = ...

local Codec = {}
ns.Codec = Codec

Codec.MAX_ENCODED = 262144      -- 256 KiB of base64 text
Codec.MAX_DECODED = 1048576     -- 1 MiB of CBOR after decompression

-- Tests replace this with a fake backend.
Codec.backend = {
	encode = function(value)
		local cbor = C_EncodingUtil.SerializeCBOR(value)
		local level = Enum.CompressionLevel and Enum.CompressionLevel.OptimizeForSize
		local packed = C_EncodingUtil.CompressString(cbor, Enum.CompressionMethod.Deflate, level)
		return C_EncodingUtil.EncodeBase64(packed)
	end,
	decode = function(text)
		local packed = C_EncodingUtil.DecodeBase64(text)
		local cbor = C_EncodingUtil.DecompressString(packed, Enum.CompressionMethod.Deflate)
		if #cbor > Codec.MAX_DECODED then
			error("decoded message too large")
		end
		return C_EncodingUtil.DeserializeCBOR(cbor)
	end,
}

function Codec.Encode(msg)
	local ok, text = pcall(Codec.backend.encode, msg)
	if not ok or type(text) ~= "string" then
		ns.Debug("encode failed", text)
		return nil
	end
	return text
end

function Codec.Decode(text)
	if type(text) ~= "string" or #text == 0 or #text > Codec.MAX_ENCODED then
		return nil
	end
	local ok, msg = pcall(Codec.backend.decode, text)
	if not ok or type(msg) ~= "table" then
		ns.Debug("decode failed", msg)
		return nil
	end
	return msg
end
