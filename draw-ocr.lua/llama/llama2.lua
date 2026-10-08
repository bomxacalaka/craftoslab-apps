-- llama2.lua: a dependency-free CraftOS/Lua port of karpathy/llama2.c.
-- The checkpoint format and inference equations follow upstream run.c.

local unpackBinary = assert(string.unpack, "CraftOS-PC with string.unpack is required")
local exp, sqrt, sin, cos = math.exp, math.sqrt, math.sin, math.cos
local floor, max = math.floor, math.max
local clock = os.clock
local useFfi = type(ffi) == "table" and type(ffi.new) == "function"

local function newNumericArray(size, initialize)
    if useFfi then return ffi.new("double[?]", size + 1) end
    local values = {}
    if initialize then
        for i = 1, size do values[i] = 0 end
    end
    return values
end

local function newLayerArrays(layers, size)
    local values = {}
    for layer = 1, layers do values[layer] = newNumericArray(size, true) end
    return values
end
local function parseArgs(argv)
    local options = {
        model = "/lab/models/stories260K.bin",
        tokenizer = "/lab/models/tok512.bin",
        steps = 256,
        temperature = 1.0,
        topp = 0.9,
        seed = 1,
        prompt = "",
        output = nil,
        metrics = nil,
        benchmarkRuns = 1,
        quiet = false,
        streamEvent = nil,
        suggestionsOutput = nil,
        suggestionsEvent = nil,
        stopAfterWord = false,
    }

    local aliases = {
        ["-m"] = "model", ["--model"] = "model",
        ["-z"] = "tokenizer", ["--tokenizer"] = "tokenizer",
        ["-n"] = "steps", ["--steps"] = "steps",
        ["-t"] = "temperature", ["--temperature"] = "temperature",
        ["-p"] = "topp", ["--topp"] = "topp",
        ["-s"] = "seed", ["--seed"] = "seed",
        ["-i"] = "prompt", ["--prompt"] = "prompt",
        ["--prompt-hex"] = "promptHex",
        ["-o"] = "output", ["--output"] = "output",
        ["--metrics"] = "metrics",
        ["--benchmark-runs"] = "benchmarkRuns",
        ["--stream-event"] = "streamEvent",
        ["--suggestions-output"] = "suggestionsOutput",
        ["--suggestions-event"] = "suggestionsEvent",
    }

    local i = 1
    while i <= #argv do
        local arg = argv[i]
        if arg == "-q" or arg == "--quiet" then
            options.quiet = true
            i = i + 1
        elseif arg == "--stop-after-word" then
            options.stopAfterWord = true
            i = i + 1
        elseif arg == "-h" or arg == "--help" then
            print("Usage: llama2.lua [--model path] [--tokenizer path] [--steps n]")
            print("                  [--temperature n] [--topp n] [--seed n]")
            print("                  [--prompt text] [--output path] [--metrics path]")
            print("                  [--benchmark-runs n] [--stream-event name]")
            print("                  [--suggestions-output path] [--suggestions-event name] [--quiet]")
            return nil
        else
            local key = aliases[arg]
            if not key or argv[i + 1] == nil then
                error("unknown or incomplete option: " .. tostring(arg), 0)
            end
            options[key] = argv[i + 1]
            i = i + 2
        end
    end

    options.steps = assert(tonumber(options.steps), "steps must be a number")
    options.temperature = max(0, (assert(tonumber(options.temperature), "temperature must be a number")))
    options.topp = assert(tonumber(options.topp), "topp must be a number")
    if options.topp < 0 or options.topp > 1 then options.topp = 0.9 end
    options.seed = assert(tonumber(options.seed), "seed must be a number")
    options.benchmarkRuns = math.floor(assert(tonumber(options.benchmarkRuns), "benchmark runs must be a number"))
    if options.benchmarkRuns < 1 or options.benchmarkRuns > 100 then
        error("benchmark runs must be between 1 and 100", 0)
    end
    if options.promptHex then
        if #options.promptHex % 2 ~= 0 or options.promptHex:find("[^%x]") then
            error("prompt hex must contain an even number of hexadecimal digits", 0)
        end
        options.prompt = options.promptHex:gsub("..", function(pair)
            return string.char(tonumber(pair, 16))
        end)
    end
    return options
end

local function readAll(path)
    local handle, message = fs.open(path, "rb")
    if not handle then error("cannot open " .. path .. ": " .. tostring(message), 0) end
    local data = handle.readAll()
    handle.close()
    if not data then error("cannot read " .. path, 0) end
    return data
end

local function cooperativeYield()
    os.queueEvent("llama2_yield")
    os.pullEvent("llama2_yield")
end

local function loadTransformer(path, quiet)
    if not quiet then write("Loading checkpoint... ") end
    local started = clock()
    local bytes = readAll(path)
    local dim, hiddenDim, nLayers, nHeads, nKvHeads, signedVocab, seqLen, byteOffset =
        unpackBinary("<i4i4i4i4i4i4i4", bytes)
    local sharedWeights = signedVocab > 0
    local vocabSize = math.abs(signedVocab)
    local floatCount = floor((#bytes - byteOffset + 1) / 4)
    local weights = newNumericArray(floatCount)

    for i = 1, floatCount do
        weights[i], byteOffset = unpackBinary("<f", bytes, byteOffset)
        if i % 32768 == 0 then cooperativeYield() end
    end
    bytes = nil
    if collectgarbage then collectgarbage("collect") end

    local cursor = 1
    local function section(count)
        local base = cursor
        cursor = cursor + count
        return base
    end

    local headSize = dim / nHeads
    local kvDim = dim * nKvHeads / nHeads
    local w = {}
    w.tokenEmbedding = section(vocabSize * dim)
    w.rmsAtt = section(nLayers * dim)
    w.wq = section(nLayers * dim * dim)
    w.wk = section(nLayers * dim * kvDim)
    w.wv = section(nLayers * dim * kvDim)
    w.wo = section(nLayers * dim * dim)
    w.rmsFfn = section(nLayers * dim)
    w.w1 = section(nLayers * dim * hiddenDim)
    w.w2 = section(nLayers * hiddenDim * dim)
    w.w3 = section(nLayers * dim * hiddenDim)
    w.rmsFinal = section(dim)
    section(seqLen * headSize / 2) -- legacy RoPE real table, no longer used
    section(seqLen * headSize / 2) -- legacy RoPE imaginary table, no longer used
    w.wcls = sharedWeights and w.tokenEmbedding or section(vocabSize * dim)

    if cursor - 1 > floatCount + 1 then error("checkpoint is shorter than its header describes", 0) end

    local ropeCos, ropeSin = {}, {}
    local halfHead = headSize / 2
    for pos = 0, seqLen - 1 do
        for pair = 0, halfHead - 1 do
            local freq = 1 / (10000 ^ ((pair * 2) / headSize))
            local index = pos * halfHead + pair + 1
            ropeCos[index] = cos(pos * freq)
            ropeSin[index] = sin(pos * freq)
        end
    end

    local transformer = {
        config = {
            dim = dim, hiddenDim = hiddenDim, nLayers = nLayers,
            nHeads = nHeads, nKvHeads = nKvHeads, vocabSize = vocabSize,
            seqLen = seqLen, headSize = headSize, kvDim = kvDim,
            kvMul = nHeads / nKvHeads,
        },
        weights = weights,
        offsets = w,
        ropeCos = ropeCos,
        ropeSin = ropeSin,
        loadSeconds = clock() - started,
        state = {
            x = newNumericArray(dim, true), xb = newNumericArray(dim, true),
            hb = newNumericArray(hiddenDim, true), hb2 = newNumericArray(hiddenDim, true), q = newNumericArray(dim, true),
            att = newLayerArrays(nHeads, seqLen), logits = newNumericArray(vocabSize, true),
            keyCache = newLayerArrays(nLayers, seqLen * kvDim),
            valueCache = newLayerArrays(nLayers, seqLen * kvDim),
        },
    }
    if not quiet then print(("done (%.2fs, %d weights, %s arrays)"):format(clock() - started, floatCount, useFfi and "FFI" or "Lua")) end
    return transformer
end

local function loadTokenizer(path, vocabSize, quiet)
    if not quiet then write("Loading tokenizer... ") end
    local bytes = readAll(path)
    local maxTokenLength, offset = unpackBinary("<i4", bytes)
    local vocab, scores, lookup = {}, {}, {}
    for token = 0, vocabSize - 1 do
        local score, length
        score, length, offset = unpackBinary("<fi4", bytes, offset)
        local piece = bytes:sub(offset, offset + length - 1)
        offset = offset + length
        local index = token + 1
        vocab[index], scores[index], lookup[piece] = piece, score, token
    end
    if not quiet then print("done") end
    return { vocab = vocab, scores = scores, lookup = lookup, maxTokenLength = maxTokenLength }
end

local function decodePiece(tokenizer, previousToken, token)
    local piece = tokenizer.vocab[token + 1]
    if previousToken == 1 and piece:sub(1, 1) == " " then piece = piece:sub(2) end
    local hex = piece:match("^<0x(%x%x)>$")
    if hex then piece = string.char(tonumber(hex, 16)) end
    if #piece == 1 then
        local byte = piece:byte()
        if byte < 32 and byte ~= 9 and byte ~= 10 and byte ~= 13 then return "" end
        if byte == 127 then return "" end
    end
    return piece
end

local function encode(tokenizer, text, bos, eos)
    local tokens = {}
    if bos then tokens[#tokens + 1] = 1 end
    if #text > 0 then tokens[#tokens + 1] = assert(tokenizer.lookup[" "], "tokenizer has no space token") end

    local position = 1
    while position <= #text do
        local first = text:byte(position)
        local length = first < 0x80 and 1 or first < 0xE0 and 2 or first < 0xF0 and 3 or 4
        local piece = text:sub(position, position + length - 1)
        local token = tokenizer.lookup[piece]
        if token then
            tokens[#tokens + 1] = token
        else
            for j = 1, #piece do tokens[#tokens + 1] = piece:byte(j) + 3 end
        end
        position = position + length
    end

    while true do
        local bestScore, bestToken, bestIndex = -1e10, nil, nil
        for i = 1, #tokens - 1 do
            local merged = tokenizer.vocab[tokens[i] + 1] .. tokenizer.vocab[tokens[i + 1] + 1]
            local token = tokenizer.lookup[merged]
            if token and tokenizer.scores[token + 1] > bestScore then
                bestScore, bestToken, bestIndex = tokenizer.scores[token + 1], token, i
            end
        end
        if not bestIndex then break end
        tokens[bestIndex] = bestToken
        table.remove(tokens, bestIndex + 1)
    end
    if eos then tokens[#tokens + 1] = 2 end
    return tokens
end

local function rmsnorm(out, x, weights, weightBase, size)
    local sum = 0
    for i = 1, size do local value = x[i]; sum = sum + value * value end
    local scale = 1 / sqrt(sum / size + 1e-5)
    for i = 1, size do out[i] = weights[weightBase + i - 1] * (scale * x[i]) end
end

-- Pairing rows reuses each input-table lookup for two dot products.
local function matmul(out, x, weights, weightBase, n, d, add)
    local row = 1
    while row <= d - 1 do
        local w1 = weightBase + (row - 1) * n
        local w2 = w1 + n
        local sum1, sum2, column = 0, 0, 1
        while column <= n - 7 do
            local x1, x2, x3, x4 = x[column], x[column + 1], x[column + 2], x[column + 3]
            local x5, x6, x7, x8 = x[column + 4], x[column + 5], x[column + 6], x[column + 7]
            sum1 = sum1
                + weights[w1] * x1 + weights[w1 + 1] * x2 + weights[w1 + 2] * x3 + weights[w1 + 3] * x4
                + weights[w1 + 4] * x5 + weights[w1 + 5] * x6 + weights[w1 + 6] * x7 + weights[w1 + 7] * x8
            sum2 = sum2
                + weights[w2] * x1 + weights[w2 + 1] * x2 + weights[w2 + 2] * x3 + weights[w2 + 3] * x4
                + weights[w2 + 4] * x5 + weights[w2 + 5] * x6 + weights[w2 + 6] * x7 + weights[w2 + 7] * x8
            w1, w2, column = w1 + 8, w2 + 8, column + 8
        end
        while column <= n do
            local value = x[column]
            sum1 = sum1 + weights[w1] * value
            sum2 = sum2 + weights[w2] * value
            w1, w2, column = w1 + 1, w2 + 1, column + 1
        end
        if add then
            out[row], out[row + 1] = out[row] + sum1, out[row + 1] + sum2
        else
            out[row], out[row + 1] = sum1, sum2
        end
        row = row + 2
    end
    if row <= d then
        local wi = weightBase + (row - 1) * n
        local sum, column = 0, 1
        while column <= n - 7 do
            sum = sum
                + weights[wi] * x[column]
                + weights[wi + 1] * x[column + 1]
                + weights[wi + 2] * x[column + 2]
                + weights[wi + 3] * x[column + 3]
                + weights[wi + 4] * x[column + 4]
                + weights[wi + 5] * x[column + 5]
                + weights[wi + 6] * x[column + 6]
                + weights[wi + 7] * x[column + 7]
            wi, column = wi + 8, column + 8
        end
        while column <= n do
            sum = sum + weights[wi] * x[column]
            wi, column = wi + 1, column + 1
        end
        out[row] = add and out[row] + sum or sum
    end
end

local function matmulAdd(out, x, weights, weightBase, n, d)
    matmul(out, x, weights, weightBase, n, d, true)
end

local function matmulPair(out1, out2, x, weights, base1, base2, n, d)
    local row = 1
    while row <= d - 1 do
        local w11 = base1 + (row - 1) * n
        local w12 = w11 + n
        local w21 = base2 + (row - 1) * n
        local w22 = w21 + n
        local sum11, sum12, sum21, sum22, column = 0, 0, 0, 0, 1
        while column <= n - 7 do
            local x1, x2, x3, x4 = x[column], x[column + 1], x[column + 2], x[column + 3]
            local x5, x6, x7, x8 = x[column + 4], x[column + 5], x[column + 6], x[column + 7]
            sum11 = sum11
                + weights[w11] * x1 + weights[w11 + 1] * x2 + weights[w11 + 2] * x3 + weights[w11 + 3] * x4
                + weights[w11 + 4] * x5 + weights[w11 + 5] * x6 + weights[w11 + 6] * x7 + weights[w11 + 7] * x8
            sum12 = sum12
                + weights[w12] * x1 + weights[w12 + 1] * x2 + weights[w12 + 2] * x3 + weights[w12 + 3] * x4
                + weights[w12 + 4] * x5 + weights[w12 + 5] * x6 + weights[w12 + 6] * x7 + weights[w12 + 7] * x8
            sum21 = sum21
                + weights[w21] * x1 + weights[w21 + 1] * x2 + weights[w21 + 2] * x3 + weights[w21 + 3] * x4
                + weights[w21 + 4] * x5 + weights[w21 + 5] * x6 + weights[w21 + 6] * x7 + weights[w21 + 7] * x8
            sum22 = sum22
                + weights[w22] * x1 + weights[w22 + 1] * x2 + weights[w22 + 2] * x3 + weights[w22 + 3] * x4
                + weights[w22 + 4] * x5 + weights[w22 + 5] * x6 + weights[w22 + 6] * x7 + weights[w22 + 7] * x8
            w11, w12 = w11 + 8, w12 + 8
            w21, w22, column = w21 + 8, w22 + 8, column + 8
        end
        while column <= n do
            local value = x[column]
            sum11 = sum11 + weights[w11] * value
            sum12 = sum12 + weights[w12] * value
            sum21 = sum21 + weights[w21] * value
            sum22 = sum22 + weights[w22] * value
            w11, w12 = w11 + 1, w12 + 1
            w21, w22, column = w21 + 1, w22 + 1, column + 1
        end
        out1[row], out1[row + 1] = sum11, sum12
        out2[row], out2[row + 1] = sum21, sum22
        row = row + 2
    end
    if row <= d then
        local w1 = base1 + (row - 1) * n
        local w2 = base2 + (row - 1) * n
        local sum1, sum2 = 0, 0
        for column = 1, n do
            local value = x[column]
            sum1 = sum1 + weights[w1] * value
            sum2 = sum2 + weights[w2] * value
            w1, w2 = w1 + 1, w2 + 1
        end
        out1[row], out2[row] = sum1, sum2
    end
end

local function matmulQkv(q, keyCache, valueCache, cacheBase, x, weights, qBase, kBase, vBase, n, qRows, kvRows)
    for row = 1, kvRows do
        local wq = qBase + (row - 1) * n
        local wk = kBase + (row - 1) * n
        local wv = vBase + (row - 1) * n
        local sumQ, sumK, sumV, column = 0, 0, 0, 1
        while column <= n - 7 do
            local x1, x2, x3, x4 = x[column], x[column + 1], x[column + 2], x[column + 3]
            local x5, x6, x7, x8 = x[column + 4], x[column + 5], x[column + 6], x[column + 7]
            sumQ = sumQ
                + weights[wq] * x1 + weights[wq + 1] * x2 + weights[wq + 2] * x3 + weights[wq + 3] * x4
                + weights[wq + 4] * x5 + weights[wq + 5] * x6 + weights[wq + 6] * x7 + weights[wq + 7] * x8
            sumK = sumK
                + weights[wk] * x1 + weights[wk + 1] * x2 + weights[wk + 2] * x3 + weights[wk + 3] * x4
                + weights[wk + 4] * x5 + weights[wk + 5] * x6 + weights[wk + 6] * x7 + weights[wk + 7] * x8
            sumV = sumV
                + weights[wv] * x1 + weights[wv + 1] * x2 + weights[wv + 2] * x3 + weights[wv + 3] * x4
                + weights[wv + 4] * x5 + weights[wv + 5] * x6 + weights[wv + 6] * x7 + weights[wv + 7] * x8
            wq, wk, wv, column = wq + 8, wk + 8, wv + 8, column + 8
        end
        while column <= n do
            local value = x[column]
            sumQ = sumQ + weights[wq] * value
            sumK = sumK + weights[wk] * value
            sumV = sumV + weights[wv] * value
            wq, wk, wv, column = wq + 1, wk + 1, wv + 1, column + 1
        end
        q[row] = sumQ
        keyCache[cacheBase + row] = sumK
        valueCache[cacheBase + row] = sumV
    end
    for row = kvRows + 1, qRows do
        local wi = qBase + (row - 1) * n
        local sum, column = 0, 1
        while column <= n - 7 do
            sum = sum
                + weights[wi] * x[column]
                + weights[wi + 1] * x[column + 1]
                + weights[wi + 2] * x[column + 2]
                + weights[wi + 3] * x[column + 3]
                + weights[wi + 4] * x[column + 4]
                + weights[wi + 5] * x[column + 5]
                + weights[wi + 6] * x[column + 6]
                + weights[wi + 7] * x[column + 7]
            wi, column = wi + 8, column + 8
        end
        while column <= n do
            sum = sum + weights[wi] * x[column]
            wi, column = wi + 1, column + 1
        end
        q[row] = sum
    end
end

local function softmaxRange(values, base, count)
    local largest = values[base]
    for i = 1, count - 1 do
        local value = values[base + i]
        if value > largest then largest = value end
    end
    local sum = 0
    for i = 0, count - 1 do
        local value = exp(values[base + i] - largest)
        values[base + i] = value
        sum = sum + value
    end
    local inverse = 1 / sum
    for i = 0, count - 1 do values[base + i] = values[base + i] * inverse end
end

local function forward(transformer, token, pos)
    local p, weights, w, s = transformer.config, transformer.weights, transformer.offsets, transformer.state
    local dim, hiddenDim, kvDim = p.dim, p.hiddenDim, p.kvDim
    local nLayers, nHeads, headSize, kvMul = p.nLayers, p.nHeads, p.headSize, p.kvMul
    local x, xb, hb, hb2, q = s.x, s.xb, s.hb, s.hb2, s.q
    local keyCaches, valueCaches, attentionHeads = s.keyCache, s.valueCache, s.att
    local ropeCos, ropeSin = transformer.ropeCos, transformer.ropeSin
    local inverseSqrtHead = 1 / sqrt(headSize)
    local embeddingBase = w.tokenEmbedding + token * dim
    for i = 1, dim do x[i] = weights[embeddingBase + i - 1] end

    for layer = 0, nLayers - 1 do
        rmsnorm(xb, x, weights, w.rmsAtt + layer * dim, dim)
        local keyCache, valueCache = keyCaches[layer + 1], valueCaches[layer + 1]
        local currentCacheBase = pos * kvDim

        matmulQkv(
            q, keyCache, valueCache, currentCacheBase, xb, weights,
            w.wq + layer * dim * dim,
            w.wk + layer * dim * kvDim,
            w.wv + layer * dim * kvDim,
            dim, dim, kvDim)

        local ropeBase = pos * (headSize / 2)
        for i = 0, dim - 1, 2 do
            local pair = (i % headSize) / 2
            local c = ropeCos[ropeBase + pair + 1]
            local si = ropeSin[ropeBase + pair + 1]
            local q0, q1 = q[i + 1], q[i + 2]
            q[i + 1], q[i + 2] = q0 * c - q1 * si, q0 * si + q1 * c
            if i < kvDim then
                local index = currentCacheBase + i + 1
                local k0, k1 = keyCache[index], keyCache[index + 1]
                keyCache[index], keyCache[index + 1] = k0 * c - k1 * si, k0 * si + k1 * c
            end
        end

        for head = 0, nHeads - 1 do
            local qBase = head * headSize
            local att = attentionHeads[head + 1]
            local attBase = 1
            local cacheHead = floor(head / kvMul) * headSize
            for time = 0, pos do
                local kBase = time * kvDim + cacheHead
                local score, i = 0, 1
                while i <= headSize - 7 do
                    score = score
                        + q[qBase + i] * keyCache[kBase + i]
                        + q[qBase + i + 1] * keyCache[kBase + i + 1]
                        + q[qBase + i + 2] * keyCache[kBase + i + 2]
                        + q[qBase + i + 3] * keyCache[kBase + i + 3]
                        + q[qBase + i + 4] * keyCache[kBase + i + 4]
                        + q[qBase + i + 5] * keyCache[kBase + i + 5]
                        + q[qBase + i + 6] * keyCache[kBase + i + 6]
                        + q[qBase + i + 7] * keyCache[kBase + i + 7]
                    i = i + 8
                end
                while i <= headSize do
                    score = score + q[qBase + i] * keyCache[kBase + i]
                    i = i + 1
                end
                att[attBase + time] = score * inverseSqrtHead
            end
            softmaxRange(att, attBase, pos + 1)
            local i = 1
            while i <= headSize - 3 do
                local sum1, sum2, sum3, sum4 = 0, 0, 0, 0
                for time = 0, pos do
                    local probability = att[attBase + time]
                    local valueBase = time * kvDim + cacheHead + i
                    sum1 = sum1 + probability * valueCache[valueBase]
                    sum2 = sum2 + probability * valueCache[valueBase + 1]
                    sum3 = sum3 + probability * valueCache[valueBase + 2]
                    sum4 = sum4 + probability * valueCache[valueBase + 3]
                end
                xb[qBase + i], xb[qBase + i + 1] = sum1, sum2
                xb[qBase + i + 2], xb[qBase + i + 3] = sum3, sum4
                i = i + 4
            end
            while i <= headSize do
                local sum = 0
                for time = 0, pos do
                    sum = sum + att[attBase + time] * valueCache[time * kvDim + cacheHead + i]
                end
                xb[qBase + i] = sum
                i = i + 1
            end
        end

        matmulAdd(x, xb, weights, w.wo + layer * dim * dim, dim, dim)

        rmsnorm(xb, x, weights, w.rmsFfn + layer * dim, dim)
        matmulPair(hb, hb2, xb, weights, w.w1 + layer * dim * hiddenDim, w.w3 + layer * dim * hiddenDim, dim, hiddenDim)
        for i = 1, hiddenDim do
            local value = hb[i]
            hb[i] = (value / (1 + exp(-value))) * hb2[i]
        end
        matmulAdd(x, hb, weights, w.w2 + layer * dim * hiddenDim, hiddenDim, dim)
    end

    rmsnorm(x, x, weights, w.rmsFinal, dim)
    matmul(s.logits, x, weights, w.wcls, dim, p.vocabSize)
    return s.logits
end

local function sample(logits, temperature, topp, vocabSize)
    if temperature == 0 then
        local bestToken, bestValue = 0, logits[1]
        for token = 1, vocabSize - 1 do
            if logits[token + 1] > bestValue then bestToken, bestValue = token, logits[token + 1] end
        end
        return bestToken
    end

    local largest = logits[1] / temperature
    for i = 1, vocabSize do
        logits[i] = logits[i] / temperature
        if logits[i] > largest then largest = logits[i] end
    end
    local sum = 0
    for i = 1, vocabSize do logits[i] = exp(logits[i] - largest); sum = sum + logits[i] end
    for i = 1, vocabSize do logits[i] = logits[i] / sum end

    local coin = math.random()
    if topp <= 0 or topp >= 1 then
        local cumulative = 0
        for token = 0, vocabSize - 1 do
            cumulative = cumulative + logits[token + 1]
            if coin < cumulative then return token end
        end
        return vocabSize - 1
    end

    local candidates, cutoff = {}, (1 - topp) / (vocabSize - 1)
    for token = 0, vocabSize - 1 do
        local probability = logits[token + 1]
        if probability >= cutoff then candidates[#candidates + 1] = { probability, token } end
    end
    table.sort(candidates, function(a, b) return a[1] > b[1] end)
    local cumulative, last = 0, #candidates
    for i = 1, #candidates do
        cumulative = cumulative + candidates[i][1]
        if cumulative > topp then last = i; break end
    end
    local target, running = coin * cumulative, 0
    for i = 1, last do
        running = running + candidates[i][1]
        if target < running then return candidates[i][2] end
    end
    return candidates[last][2]
end

local function generate(transformer, tokenizer, options)
    local promptTokens = encode(tokenizer, options.prompt, true, false)
    local token, pieces, continuation = promptTokens[1], {}, ""
    local steps = math.min(options.steps == 0 and transformer.config.seqLen or options.steps, transformer.config.seqLen)
    local started = clock()
    math.randomseed(options.seed)

    for pos = 0, steps - 1 do
        local logits = forward(transformer, token, pos)
        local nextToken
        if pos < #promptTokens - 1 then
            nextToken = promptTokens[pos + 2]
        else
            nextToken = sample(logits, options.temperature, options.topp, transformer.config.vocabSize)
        end
        if nextToken == 1 then break end
        local piece = decodePiece(tokenizer, token, nextToken)
        pieces[#pieces + 1] = piece
        if not options.quiet then write(piece) end
        token = nextToken
        local shouldStop = false
        if pos >= #promptTokens - 1 then
            continuation = continuation .. piece
            shouldStop = options.stopAfterWord and continuation:match("^%s*[^%s]+%s") ~= nil
        end
        if options.streamEvent and pos >= #promptTokens - 1 then
            if options.streamIndex then os.queueEvent(options.streamEvent, options.streamIndex, piece)
            else os.queueEvent(options.streamEvent, piece) end
            cooperativeYield()
        elseif pos % 16 == 15 then
            cooperativeYield()
        end
        if shouldStop then break end
    end
    if not options.quiet then print() end
    return table.concat(pieces), clock() - started, #pieces
end

local options = parseArgs({...})
if not options then return end

local transformer = loadTransformer(options.model, options.quiet)
local tokenizer = loadTokenizer(options.tokenizer, transformer.config.vocabSize, options.quiet)
if options.suggestionsOutput then
    local configurations = {
        { temperature = 0, topp = 1, seed = options.seed },
        { temperature = 0.7, topp = 0.9, seed = options.seed + 101 },
        { temperature = 1.0, topp = 0.8, seed = options.seed + 202 },
    }
    local seen, words, wordKinds = {}, {}, {}
    for index, configuration in ipairs(configurations) do
        local word = ""
        for attempt = 0, 5 do
            if options.suggestionsEvent then
                os.queueEvent(options.suggestionsEvent, index, "", true)
                cooperativeYield()
            end
            local temperature = attempt == 0 and configuration.temperature or math.min(1.3, 0.8 + attempt * 0.1)
            local seed = configuration.seed + attempt * 1009 + index * 17
            local suggestionOptions = {
                prompt = options.prompt, steps = 0, temperature = temperature,
                topp = configuration.topp, seed = seed, quiet = true, stopAfterWord = true,
                streamEvent = options.suggestionsEvent, streamIndex = index,
            }
            local generated = generate(transformer, tokenizer, suggestionOptions)
            local continuation = generated:sub(1, #options.prompt) == options.prompt
                and generated:sub(#options.prompt + 1) or generated
            local candidate = continuation:match("^%s*([^%s]+)") or ""
            if candidate ~= "" and not seen[candidate] then
                word = candidate
                wordKinds[index] = continuation:match("^%s") and "next" or "complete"
                break
            end
        end
        if word ~= "" then seen[word] = true end
        words[#words + 1] = word
    end
    local handle, message = fs.open(options.suggestionsOutput, "w")
    if not handle then error("cannot open suggestions output: " .. tostring(message), 0) end
    for index, word in ipairs(words) do
        handle.writeLine((wordKinds[index] or "next") .. "\t" .. word)
    end
    handle.close()
    return
end
local benchmarkRuns = options.benchmarkRuns
local text, elapsed, count
local totalElapsed, totalTokens = 0, 0
for run = 1, benchmarkRuns do
    text, elapsed, count = generate(transformer, tokenizer, options)
    totalElapsed = totalElapsed + elapsed
    totalTokens = totalTokens + count
    if not options.quiet then
        print(("Benchmark run %d/%d: %.3fs (%.3f tokens/s)"):format(
            run, benchmarkRuns, elapsed, count / math.max(elapsed, 1e-9)))
    end
end

if options.output then
    local handle, message = fs.open(options.output, "wb")
    if not handle then error("cannot open output " .. options.output .. ": " .. tostring(message), 0) end
    handle.write(text)
    handle.close()
end

local tokensPerSecond = totalTokens / math.max(totalElapsed, 1e-9)
if options.metrics then
    local handle, message = fs.open(options.metrics, "w")
    if not handle then error("cannot open metrics " .. options.metrics .. ": " .. tostring(message), 0) end
    handle.writeLine(("load_seconds=%.6f"):format(transformer.loadSeconds))
    handle.writeLine(("generation_seconds=%.6f"):format(totalElapsed))
    handle.writeLine(("tokens=%d"):format(totalTokens))
    handle.writeLine(("tokens_per_second=%.6f"):format(tokensPerSecond))
    handle.writeLine("array_backend=" .. (useFfi and "ffi-double" or "lua-table"))
    handle.close()
end
if not options.quiet then
    print(("Average over %d runs: %.3f tokens/s"):format(benchmarkRuns, tokensPerSecond))
end
