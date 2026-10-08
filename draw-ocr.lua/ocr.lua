local letterModelPath, digitModelPath = "model/letters.bin", "model/digits.bin"
local llamaProgramPath, llamaModelPath, llamaTokenizerPath =
    "llama/llama2.lua", "llama/models/stories260K.bin", "llama/models/tok512.bin"
local llamaSteps, llamaTemperature, llamaTopP, llamaSeed = 160, 0.8, 0.9, 1
local arguments = {...}
for index = 1, #arguments, 2 do
    if arguments[index] == "--letters-model" and arguments[index + 1] then letterModelPath = arguments[index + 1]
    elseif arguments[index] == "--digits-model" and arguments[index + 1] then digitModelPath = arguments[index + 1] end
    if arguments[index] == "--llama-program" and arguments[index + 1] then llamaProgramPath = arguments[index + 1]
    elseif arguments[index] == "--llama-model" and arguments[index + 1] then llamaModelPath = arguments[index + 1]
    elseif arguments[index] == "--llama-tokenizer" and arguments[index + 1] then llamaTokenizerPath = arguments[index + 1]
    elseif arguments[index] == "--llama-steps" and arguments[index + 1] then llamaSteps = tonumber(arguments[index + 1]) or llamaSteps
    elseif arguments[index] == "--llama-temperature" and arguments[index + 1] then
        llamaTemperature = tonumber(arguments[index + 1]) or llamaTemperature
    elseif arguments[index] == "--llama-topp" and arguments[index + 1] then llamaTopP = tonumber(arguments[index + 1]) or llamaTopP
    elseif arguments[index] == "--llama-seed" and arguments[index + 1] then llamaSeed = tonumber(arguments[index + 1]) or llamaSeed end
end

local function loadModel(path)
    local handle, message = fs.open(path, "rb")
    if not handle then error("cannot open OCR model: " .. tostring(message), 0) end
    local bytes = handle.readAll()
    handle.close()
    local magic, inputSize, channels1, channels2, hidden, classes, pool, position =
        string.unpack("<c8I4I4I4I4I4I4", bytes)
    assert(magic == "CCOCR2\0\0", "unsupported OCR model")
    assert(inputSize == 28 and channels1 == 16 and channels2 == 32 and hidden == 96 and pool == 2,
        "unexpected model shape")
    assert(classes == 10 or classes == 26, "unexpected class count")
    local function floats(count)
        local values = {}
        for index = 1, count do values[index], position = string.unpack("<f", bytes, position) end
        return values
    end
    local model = {
        classes = classes,
        conv1Weights = floats(16 * 5 * 5), conv1Bias = floats(16),
        conv2Weights = floats(32 * 16 * 3 * 3), conv2Bias = floats(32),
        featureWeights = floats(96 * 32 * 5 * 5), featureBias = floats(96),
        outputWeights = floats(classes * 96), outputBias = floats(classes),
    }
    bytes = nil
    return model
end

local function convolution(input, inputChannels, inputSize, weights, bias, outputChannels, kernel, stride)
    local outputSize = math.floor((inputSize - kernel) / stride) + 1
    local output = {}
    local inputPlane, kernelPlane = inputSize * inputSize, kernel * kernel
    for outputChannel = 0, outputChannels - 1 do
        local outputBase = outputChannel * outputSize * outputSize
        local weightChannelBase = outputChannel * inputChannels * kernelPlane
        for outputY = 0, outputSize - 1 do
            local inputY = outputY * stride
            for outputX = 0, outputSize - 1 do
                local sum = bias[outputChannel + 1]
                local inputX = outputX * stride
                for inputChannel = 0, inputChannels - 1 do
                    local inputBase = inputChannel * inputPlane + inputY * inputSize + inputX
                    local weightBase = weightChannelBase + inputChannel * kernelPlane
                    for kernelY = 0, kernel - 1 do
                        local ii = inputBase + kernelY * inputSize + 1
                        local wi = weightBase + kernelY * kernel + 1
                        for kernelX = 0, kernel - 1 do
                            sum = sum + input[ii + kernelX] * weights[wi + kernelX]
                        end
                    end
                end
                output[outputBase + outputY * outputSize + outputX + 1] = math.max(0, sum)
            end
        end
    end
    return output, outputSize
end

local function maxPool(input, channels, inputSize)
    local outputSize = math.floor(inputSize / 2)
    local output, inputPlane, outputPlane = {}, inputSize * inputSize, outputSize * outputSize
    for channel = 0, channels - 1 do
        local inputBase, outputBase = channel * inputPlane, channel * outputPlane
        for y = 0, outputSize - 1 do
            local row = inputBase + y * 2 * inputSize
            for x = 0, outputSize - 1 do
                local index = row + x * 2 + 1
                output[outputBase + y * outputSize + x + 1] = math.max(
                    input[index], input[index + 1], input[index + inputSize], input[index + inputSize + 1])
            end
        end
    end
    return output, outputSize
end

local function predict(model, image, mode)
    local hidden1, size1 = convolution(image, 1, 28, model.conv1Weights, model.conv1Bias, 16, 5, 1)
    hidden1, size1 = maxPool(hidden1, 16, size1)
    local hidden2, size2 = convolution(hidden1, 16, size1, model.conv2Weights, model.conv2Bias, 32, 3, 1)
    hidden1 = nil
    hidden2, size2 = maxPool(hidden2, 32, size2)
    local features = {}
    for neuron = 0, 95 do
        local sum, base = model.featureBias[neuron + 1], neuron * 800
        for index = 1, 800 do sum = sum + hidden2[index] * model.featureWeights[base + index] end
        features[neuron + 1] = math.max(0, sum)
    end
    hidden2 = nil
    local logits = {}
    local largest = -math.huge
    for class = 0, model.classes - 1 do
        local sum, base = model.outputBias[class + 1], class * 96
        for index = 1, 96 do sum = sum + features[index] * model.outputWeights[base + index] end
        logits[class + 1] = sum
        if sum > largest then largest = sum end
    end
    local total = 0
    for index = 1, model.classes do logits[index] = math.exp(logits[index] - largest); total = total + logits[index] end
    local ranked = {}
    for index = 1, model.classes do
        local symbol = mode == "letters" and string.char(64 + index) or tostring(index - 1)
        ranked[index] = { letter = symbol, confidence = logits[index] / total }
    end
    table.sort(ranked, function(left, right) return left.confidence > right.confidence end)
    return ranked
end

local nativeTerminal = term.current()
local function findAdvancedMonitor()
    local bestName, bestMonitor, bestCapacityWidth, bestCapacityHeight, bestArea, foundAdvanced
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "monitor" then
            local candidate = peripheral.wrap(name)
            if candidate and candidate.isColor() then
                foundAdvanced = true
                local candidateWidth, candidateHeight = candidate.getSize()
                local currentScale = candidate.getTextScale()
                local capacityWidth, capacityHeight = candidateWidth * currentScale, candidateHeight * currentScale
                local area = capacityWidth * capacityHeight
                if capacityWidth / 0.5 >= 36 and capacityHeight / 0.5 >= 18
                    and (not bestArea or area > bestArea) then
                    bestName, bestMonitor, bestCapacityWidth, bestCapacityHeight, bestArea =
                        name, candidate, capacityWidth, capacityHeight, area
                end
            end
        end
    end
    if not bestMonitor then return nil, nil, foundAdvanced, nil end

    -- Use the largest half-step which still leaves room for the complete interface.
    local scale = math.min(5, math.floor(math.min(bestCapacityWidth / 36, bestCapacityHeight / 18) * 2) / 2)
    scale = math.max(0.5, scale)
    if bestMonitor.getTextScale() ~= scale then bestMonitor.setTextScale(scale) end
    local fittedWidth, fittedHeight = bestMonitor.getSize()
    while (fittedWidth < 36 or fittedHeight < 18) and scale > 0.5 do
        scale = scale - 0.5
        bestMonitor.setTextScale(scale)
        fittedWidth, fittedHeight = bestMonitor.getSize()
    end
    if fittedWidth < 36 or fittedHeight < 18 then return nil, nil, true, nil end
    return bestName, bestMonitor, true, scale
end

local monitorName, monitor, _, monitorScale = findAdvancedMonitor()
local usingMonitor = monitor ~= nil
if usingMonitor then term.redirect(monitor) end
local width, height = term.getSize()
if width < 36 or height < 18 then error("Draw OCR needs a terminal at least 36x18", 0) end
local canvasX, canvasY = 2, 2
local sidebarWidth = 15
local canvasWidth, canvasHeight = width - sidebarWidth - 4, height - 3
local sidebarX = canvasX + canvasWidth + 2
local ink = {}
local text = ""
local response, responseStreaming
local suggestions = {}
local suggestionCompletes = {}
local canCompleteCurrent = false
local suggestionPrefix = ""
local status = "Draw one letter"
local lastX, lastY
local autoRecognize = true
local autoTimer
local suggestionTimer
local mode, letterCase = "letters", "lower"
local touchErase = false
local touchTimer, lastTouchX, lastTouchY

local function key(x, y) return y * 256 + x end
local function inside(x, y)
    return x >= canvasX and x < canvasX + canvasWidth and y >= canvasY and y < canvasY + canvasHeight
end

local function drawCell(x, y)
    term.setCursorPos(x, y)
    term.setBackgroundColor(ink[key(x, y)] and colors.white or colors.black)
    term.write(" ")
end

local function setInk(x, y, enabled)
    if not inside(x, y) then return end
    if enabled then ink[key(x, y)] = true else ink[key(x, y)] = nil end
    drawCell(x, y)
end

local function line(x0, y0, x1, y1, enabled)
    local dx, sx = math.abs(x1 - x0), x0 < x1 and 1 or -1
    local dy, sy = -math.abs(y1 - y0), y0 < y1 and 1 or -1
    local errorValue = dx + dy
    while true do
        setInk(x0, y0, enabled)
        if x0 == x1 and y0 == y1 then break end
        local twice = 2 * errorValue
        if twice >= dy then errorValue, x0 = errorValue + dy, x0 + sx end
        if twice <= dx then errorValue, y0 = errorValue + dx, y0 + sy end
    end
end

local function clearInk()
    ink = {}
    term.setBackgroundColor(colors.black)
    for y = canvasY, canvasY + canvasHeight - 1 do
        term.setCursorPos(canvasX, y)
        term.write((" "):rep(canvasWidth))
    end
end

local function toImage()
    local minX, minY, maxX, maxY
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        minX, minY = math.min(minX or x, x), math.min(minY or y, y)
        maxX, maxY = math.max(maxX or x, x), math.max(maxY or y, y)
    end
    if not minX then return nil end
    local sourceWidth, sourceHeight = maxX - minX + 1, maxY - minY + 1
    -- A terminal has roughly half as many drawable rows as model pixels. Treat each row as two vertical pixels.
    local verticalScale = 2
    local scale = math.min(20 / sourceWidth, 20 / (sourceHeight * verticalScale))
    local drawnWidth, drawnHeight = sourceWidth * scale, sourceHeight * verticalScale * scale
    local offsetX, offsetY = (28 - drawnWidth) / 2, (28 - drawnHeight) / 2
    local image = {}
    for index = 1, 784 do image[index] = 0 end
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        local targetX = math.floor(offsetX + (x - minX + 0.5) * scale)
        local targetY = math.floor(offsetY + (y - minY + 0.5) * verticalScale * scale)
        for oy = -1, 1 do
            for ox = -1, 1 do
                local px, py = targetX + ox, targetY + oy
                if px >= 0 and px < 28 and py >= 0 and py < 28 then
                    local value = ox == 0 and oy == 0 and 1 or 0.45
                    local index = py * 28 + px + 1
                    if value > image[index] then image[index] = value end
                end
            end
        end
    end
    return image
end

local buttons = {
    { row = 1, label = "Touch: DRAW", action = "touchMode", monitorOnly = true },
    { row = 2, label = "  Auto: ON  ", action = "auto" },
    { row = 4, label = " Mode: ABC ", action = "mode" },
    { row = 6, label = " Recognize ", action = "recognize" },
    { row = 8, label = " Clear ink ", action = "clear" },
    { row = 10, label = "   Space   ", action = "space" },
    { row = 12, label = " Backspace ", action = "backspace" },
    { row = 14, label = " Clear text ", action = "clearText" },
    { row = 16, label = "    Quit    ", action = "quit" },
}

local function clipped(value, maximum)
    value = tostring(value)
    return #value <= maximum and value or value:sub(1, maximum)
end

local function renderSidebar()
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    for y = 1, height do term.setCursorPos(sidebarX, y); term.write((" "):rep(sidebarWidth)) end
    if not usingMonitor then term.setCursorPos(sidebarX + 1, 1); term.write("DRAW OCR") end
    for _, button in ipairs(buttons) do
        if button.row <= height - 2 and (not button.monitorOnly or usingMonitor) then
            term.setCursorPos(sidebarX + 1, button.row)
            term.setBackgroundColor(colors.lightGray)
            term.setTextColor(colors.black)
            local label = button.label
            if button.action == "auto" then label = autoRecognize and "  Auto: ON  " or " Auto: OFF  "
            elseif button.action == "mode" then
                label = mode == "digits" and " Mode: 123 " or letterCase == "lower" and " Mode: abc " or " Mode: ABC "
            end
            if button.action == "touchMode" then label = touchErase and "Touch: ERASE" or "Touch: DRAW" end
            term.write(clipped(label, sidebarWidth - 2))
        end
    end
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    term.setCursorPos(sidebarX + 1, height - 1); term.write(clipped(status, sidebarWidth - 2))
end

local function renderText()
    local sendWidth, promptWidth = 8, width - 8
    local available = math.max(0, promptWidth - 6)
    local shown = #text <= available and text or text:sub(#text - available + 1)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    term.setCursorPos(1, height)
    term.write(("Text: " .. shown .. (" "):rep(promptWidth)):sub(1, promptWidth))
    term.setBackgroundColor(colors.green)
    term.setCursorPos(promptWidth + 1, height)
    term.write("  SEND  ")
end

local function renderSuggestions()
    local totalWidth = sidebarX - 1
    for index = 1, 3 do
        local firstX = math.floor((index - 1) * totalWidth / 3) + 1
        local lastX = math.floor(index * totalWidth / 3)
        local buttonWidth = lastX - firstX + 1
        local label = suggestions[index] or "..."
        label = clipped(label, math.max(1, buttonWidth - 2))
        local left = math.floor((buttonWidth - #label) / 2)
        term.setCursorPos(firstX, height - 1)
        term.setBackgroundColor(suggestions[index] and colors.lightBlue or colors.gray)
        term.setTextColor(suggestions[index] and colors.black or colors.lightGray)
        term.write((" "):rep(left) .. label .. (" "):rep(buttonWidth - left - #label))
    end
end

local cancelAutoTimer
local model = loadModel(letterModelPath)

local function toggleMode()
    cancelAutoTimer()
    local previousMode = mode
    if mode == "letters" and letterCase == "lower" then
        letterCase = "upper"
    elseif mode == "letters" then
        mode = "digits"
    else
        mode, letterCase = "letters", "lower"
    end
    if previousMode ~= mode then
        status = mode == "letters" and "Loading abc..." or "Loading 123..."
        renderSidebar()
        model = nil
        -- CraftOS omits Lua's manual garbage-collection API. The VM reclaims the old model automatically.
        model = loadModel(mode == "letters" and letterModelPath or digitModelPath)
    end
    status = mode == "digits" and "Number mode" or letterCase == "lower" and "Lowercase" or "Uppercase"
end

cancelAutoTimer = function()
    if autoTimer then os.cancelTimer(autoTimer); autoTimer = nil end
    if touchTimer then os.cancelTimer(touchTimer); touchTimer = nil end
    if suggestionTimer then os.cancelTimer(suggestionTimer); suggestionTimer = nil end
end

local function scheduleAutoRecognize()
    cancelAutoTimer()
    if autoRecognize and next(ink) then autoTimer = os.startTimer(0.0) end
end

local function scheduleSuggestionRefresh()
    if suggestionTimer then os.cancelTimer(suggestionTimer) end
    suggestionTimer = text:match("%S") and os.startTimer(0.8) or nil
end

local function isStraightVerticalStroke()
    local minX, minY, maxX, maxY
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        minX, minY = math.min(minX or x, x), math.min(minY or y, y)
        maxX, maxY = math.max(maxX or x, x), math.max(maxY or y, y)
    end
    if not minX then return false end
    local strokeWidth, strokeHeight = maxX - minX + 1, maxY - minY + 1
    return strokeHeight >= 5 and strokeWidth <= math.max(2, math.floor(strokeHeight * 0.18))
end

local function isHorizontalSpaceGesture()
    local minX, minY, maxX, maxY
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        minX, minY = math.min(minX or x, x), math.min(minY or y, y)
        maxX, maxY = math.max(maxX or x, x), math.max(maxY or y, y)
    end
    if not minX then return false end
    local strokeWidth, strokeHeight = maxX - minX + 1, maxY - minY + 1
    -- Permit a noticeable slope or wobble, but require a clearly horizontal overall shape.
    return strokeWidth >= 6 and strokeWidth >= strokeHeight * 2.5
end

local function isClosedRoundGesture()
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        minX, minY, maxX, maxY = math.min(minX, x), math.min(minY, y), math.max(maxX, x), math.max(maxY, y)
    end
    if maxX == -math.huge or maxX - minX < 4 or maxY - minY < 4 then return false end

    -- Flood the background from outside the bounding box. Any unvisited empty cell is a closed hole.
    local outside, queueX, queueY = {}, { minX - 1 }, { minY - 1 }
    local first, last = 1, 1
    outside[key(minX - 1, minY - 1)] = true
    while first <= last do
        local x, y = queueX[first], queueY[first]
        first = first + 1
        local neighbours = { x - 1, y, x + 1, y, x, y - 1, x, y + 1 }
        for index = 1, 8, 2 do
            local nx, ny = neighbours[index], neighbours[index + 1]
            local packed = key(nx, ny)
            if nx >= minX - 1 and nx <= maxX + 1 and ny >= minY - 1 and ny <= maxY + 1
                and not ink[packed] and not outside[packed] then
                outside[packed] = true
                last = last + 1
                queueX[last], queueY[last] = nx, ny
            end
        end
    end
    local hasHole = false
    for y = minY, maxY do
        for x = minX, maxX do
            local packed = key(x, y)
            if not ink[packed] and not outside[packed] then hasHole = true; break end
        end
        if hasHole then break end
    end
    if not hasHole then return false end

    -- A D also encloses a hole, but normally has a nearly continuous straight left spine.
    local straightLeftRows = 0
    for y = minY, maxY do
        if ink[key(minX, y)] or ink[key(minX + 1, y)] then straightLeftRows = straightLeftRows + 1 end
    end
    return straightLeftRows / (maxY - minY + 1) < 0.82
end

local function isBackspaceGesture()
    local minX, minY, maxX, maxY = math.huge, math.huge, -math.huge, -math.huge
    local rows = {}
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        minX, minY, maxX, maxY = math.min(minX, x), math.min(minY, y), math.max(maxX, x), math.max(maxY, y)
        local row = rows[y] or { sum = 0, count = 0, minimum = x, maximum = x }
        row.sum, row.count = row.sum + x, row.count + 1
        row.minimum, row.maximum = math.min(row.minimum, x), math.max(row.maximum, x)
        rows[y] = row
    end
    if maxX == -math.huge then return false end
    local width, height = maxX - minX + 1, maxY - minY + 1
    if width < 6 or height < 7 or width < height * 0.5 or width > height * 2.2 then return false end

    local narrowRows, rowCount = 0, 0
    for _, row in pairs(rows) do
        rowCount = rowCount + 1
        if row.maximum - row.minimum + 1 <= width * 0.45 then narrowRows = narrowRows + 1 end
    end
    -- An arrow has one narrow diagonal arm on almost every row. Letters such as M span both sides at once.
    if narrowRows / rowCount < 0.65 then return false end

    local means, vertexY, vertexX = {}, nil, math.huge
    for y = minY, maxY do
        if rows[y] then
            means[y] = rows[y].sum / rows[y].count
            if means[y] < vertexX then vertexX, vertexY = means[y], y end
        end
    end
    if not vertexY or vertexY < minY + height * 0.25 or vertexY > maxY - height * 0.25 then return false end

    local function correlation(firstY, lastY)
        local count, sumY, sumX, sumYY, sumXX, sumYX = 0, 0, 0, 0, 0, 0
        for y = firstY, lastY do
            local x = means[y]
            if x then
                count, sumY, sumX = count + 1, sumY + y, sumX + x
                sumYY, sumXX, sumYX = sumYY + y * y, sumXX + x * x, sumYX + y * x
            end
        end
        if count < 3 then return 0 end
        local numerator = count * sumYX - sumY * sumX
        local denominator = math.sqrt((count * sumYY - sumY * sumY) * (count * sumXX - sumX * sumX))
        return denominator > 0 and numerator / denominator or 0
    end

    local topX, bottomX = means[minY], means[maxY]
    if not topX or not bottomX then return false end
    return topX - vertexX >= width * 0.30 and bottomX - vertexX >= width * 0.30
        and correlation(minY, vertexY) <= -0.70 and correlation(vertexY, maxY) >= 0.70
end

local function recognizeInk()
    cancelAutoTimer()
    local image = toImage()
    if not image then status = "Draw first"; return false end
    status = "Thinking..."
    renderSidebar()
    local completedWord = false
    if isStraightVerticalStroke() then
        local symbol = mode == "digits" and "1" or letterCase == "lower" and "i" or "I"
        text = text .. symbol
        suggestions = {}
        status = symbol .. " (straight)"
    elseif isBackspaceGesture() then
        text = text:sub(1, -2)
        suggestions = {}
        status = "Backspace (<)"
    elseif isHorizontalSpaceGesture() then
        text = text .. " "
        suggestions = {}
        completedWord = true
        status = "Space (gesture)"
    else
        local ranked = predict(model, image, mode)
        local result = ranked[1]
        if mode == "letters" and (result.letter == "U" or result.letter == "D") and isClosedRoundGesture() then
            for index = 2, math.min(3, #ranked) do
                if ranked[index].letter == "O" then result = ranked[index]; status = "O (closed loop)"; break end
            end
        end
        local output = mode == "letters" and letterCase == "lower" and result.letter:lower() or result.letter
        text = text .. output
        suggestions = {}
        if status ~= "O (closed loop)" then
            local first = mode == "letters" and letterCase == "lower" and ranked[1].letter:lower() or ranked[1].letter
            local second = mode == "letters" and letterCase == "lower" and ranked[2].letter:lower() or ranked[2].letter
            status = ("%s %.0f%% %s %.0f%%"):format(first, ranked[1].confidence * 100,
                second, ranked[2].confidence * 100)
        elseif letterCase == "lower" then
            status = "o (closed loop)"
        end
    end
    clearInk()
    renderSuggestions()
    if completedWord then os.queueEvent("draw_ocr_suggest") else scheduleSuggestionRefresh() end
    return true
end

local running
local function activateControl(y)
    for _, item in ipairs(buttons) do
        if y == item.row and (not item.monitorOnly or usingMonitor) then
            cancelAutoTimer()
            lastTouchX, lastTouchY = nil, nil
            if item.action == "recognize" then
                recognizeInk()
            elseif item.action == "auto" then
                autoRecognize = not autoRecognize
                if not autoRecognize then cancelAutoTimer() end
                status = autoRecognize and "Auto enabled" or "Auto disabled"
            elseif item.action == "mode" then toggleMode()
            elseif item.action == "touchMode" then
                cancelAutoTimer()
                touchErase = not touchErase
                status = touchErase and "Touch erases" or "Touch draws"
            elseif item.action == "clear" then response = nil; cancelAutoTimer(); clearInk(); status = "Ink cleared"
            elseif item.action == "space" then
                response = nil; suggestions = {}; text = text .. " "; status = "Space added"
                os.queueEvent("draw_ocr_suggest")
            elseif item.action == "backspace" then
                response = nil; suggestions = {}; text = text:sub(1, -2); status = "Removed last"
                scheduleSuggestionRefresh()
            elseif item.action == "clearText" then
                text = ""; response = nil; suggestions = {}; status = "Text cleared"
            elseif item.action == "quit" then running = false end
            renderSidebar()
            renderText()
            renderSuggestions()
            return true
        end
    end
    return false
end

local function renderDisplay()
    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setTextColor(colors.lightGray)
    term.setCursorPos(canvasX, 1)
    local instruction = usingMonitor and "Touch monitor to draw; tap DRAW to erase"
        or "Draw with left mouse; right mouse erases"
    term.write(clipped(instruction, canvasWidth))
    renderSidebar()
    renderText()
    renderSuggestions()
    if response then
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        local lines = {}
        for paragraph in (response .. "\n"):gmatch("(.-)\n") do
            local text = paragraph
            if text == "" then
                lines[#lines + 1] = ""
            else
                while #text > canvasWidth do
                    local chunk = text:sub(1, canvasWidth)
                    local split = chunk:match("^.*()%s")
                    if not split or split < 2 then split = canvasWidth end
                    lines[#lines + 1] = text:sub(1, split):gsub("%s+$", "")
                    text = text:sub(split + 1):gsub("^%s+", "")
                end
                lines[#lines + 1] = text
            end
        end
        local firstLine = responseStreaming and math.max(1, #lines - canvasHeight + 1) or 1
        for row = 1, math.min(#lines - firstLine + 1, canvasHeight) do
            term.setCursorPos(canvasX, canvasY + row - 1)
            term.write(clipped(lines[firstLine + row - 1], canvasWidth))
        end
    else
        for packed in pairs(ink) do
            local y, x = math.floor(packed / 256), packed % 256
            if inside(x, y) then drawCell(x, y) end
        end
    end
end

local function remapInk(oldX, oldY, oldWidth, oldHeight)
    if oldWidth == canvasWidth and oldHeight == canvasHeight then return end
    local remapped = {}
    for packed in pairs(ink) do
        local y, x = math.floor(packed / 256), packed % 256
        local relativeX = oldWidth > 1 and (x - oldX) / (oldWidth - 1) or 0.5
        local relativeY = oldHeight > 1 and (y - oldY) / (oldHeight - 1) or 0.5
        local newX = canvasX + math.floor(relativeX * (canvasWidth - 1) + 0.5)
        local newY = canvasY + math.floor(relativeY * (canvasHeight - 1) + 0.5)
        if inside(newX, newY) then remapped[key(newX, newY)] = true end
    end
    ink = remapped
end

local function reloadDisplay(reason)
    cancelAutoTimer()
    lastX, lastY, lastTouchX, lastTouchY = nil, nil, nil, nil
    local oldX, oldY, oldWidth, oldHeight = canvasX, canvasY, canvasWidth, canvasHeight
    local foundAdvanced
    monitorName, monitor, foundAdvanced, monitorScale = findAdvancedMonitor()
    usingMonitor = monitor ~= nil
    term.redirect(usingMonitor and monitor or nativeTerminal)
    width, height = term.getSize()
    canvasWidth, canvasHeight = width - sidebarWidth - 4, height - 3
    sidebarX = canvasX + canvasWidth + 2
    if width < 36 or height < 18 then
        error("Draw OCR needs a display at least 36x18", 0)
    end
    remapInk(oldX, oldY, oldWidth, oldHeight)
    if usingMonitor then
        status = ("Scale %.1fx"):format(monitorScale)
    elseif foundAdvanced then
        status = "Monitor too small"
    else
        status = "Using computer"
    end
    renderDisplay()
end

local function sendPrompt()
    cancelAutoTimer()
    lastX, lastY, lastTouchX, lastTouchY = nil, nil, nil, nil
    if text:match("^%s*$") then status = "Write prompt"; renderSidebar(); return end

    local prompt = text
    local outputPath = ".draw-ocr-llama-output.txt"
    local streamEvent = "draw_ocr_llama_token"
    if fs.exists(outputPath) then fs.delete(outputPath) end
    suggestions = {}
    response = prompt
    responseStreaming = true
    model = nil
    status = "Llama loading"
    renderDisplay()
    local callOk, runOk
    parallel.waitForAny(
        function()
            -- shell.run joins and tokenizes its arguments again, which splits prompts
            -- containing spaces. shell.execute preserves each argument verbatim.
            callOk, runOk = pcall(shell.execute, llamaProgramPath,
                "--model", llamaModelPath, "--tokenizer", llamaTokenizerPath,
                "--steps", tostring(llamaSteps), "--temperature", tostring(llamaTemperature),
                "--topp", tostring(llamaTopP), "--seed", tostring(llamaSeed),
                "--benchmark-runs", "1", "--prompt", prompt, "--output", outputPath,
                "--stream-event", streamEvent, "--quiet")
        end,
        function()
            while true do
                local event, value = os.pullEvent()
                if event == streamEvent then
                    response = response .. tostring(value or "")
                    status = "Generating..."
                    renderDisplay()
                elseif event == "peripheral" and peripheral.getType(value) == "monitor" then
                    reloadDisplay("Monitor connected")
                    status = "Generating..."
                    renderDisplay()
                elseif event == "peripheral_detach" and value == monitorName then
                    reloadDisplay("Monitor removed")
                    status = "Generating..."
                    renderDisplay()
                elseif event == "monitor_resize" and (value == monitorName or not usingMonitor) then
                    reloadDisplay("Monitor resized")
                    status = "Generating..."
                    renderDisplay()
                end
            end
        end)

    -- Generation may have consumed monitor events, so rescan peripherals before drawing again.
    reloadDisplay("Llama finished")
    status = "Reloading OCR"
    renderDisplay()
    model = loadModel(mode == "letters" and letterModelPath or digitModelPath)

    if not callOk or not runOk or not fs.exists(outputPath) then
        if fs.exists(outputPath) then fs.delete(outputPath) end
        response = "Generation failed. Check cc-appstore.log."
        responseStreaming = false
        status = "Llama failed"
    else
        local handle = fs.open(outputPath, "rb")
        local generated = handle and handle.readAll() or ""
        if handle then handle.close() end
        fs.delete(outputPath)
        if generated:sub(1, #prompt) ~= prompt then generated = prompt .. generated end
        response = generated ~= "" and generated or "(no continuation generated)"
        responseStreaming = false
        status = "Llama complete"
    end
    renderDisplay()
end

local function refreshSuggestions()
    if not text:match("%S") then return end
    -- Without trailing whitespace the user is still writing a word. Let Llama
    -- complete that word ("th" -> "the") instead of asking what follows the
    -- artificial prompt "th ". An explicit space switches to next-word mode.
    local prompt = text
    canCompleteCurrent = not text:match("%s$")
    suggestionPrefix = canCompleteCurrent and (text:match("([^%s]+)$") or "") or ""
    local outputPath = ".draw-ocr-suggestions.txt"
    if fs.exists(outputPath) then fs.delete(outputPath) end
    suggestions = {}
    suggestionCompletes = {}
    model = nil
    status = "Suggesting..."
    renderDisplay()
    local streamEvent = "draw_ocr_suggestion_token"
    local drafts, callOk, runOk = {}, nil, nil
    parallel.waitForAny(
        function()
            callOk, runOk = pcall(shell.execute, llamaProgramPath,
                "--model", llamaModelPath, "--tokenizer", llamaTokenizerPath,
                "--prompt", prompt, "--seed", tostring(llamaSeed),
                "--suggestions-output", outputPath, "--suggestions-event", streamEvent, "--quiet")
        end,
        function()
            while true do
                local event, value, piece, reset = os.pullEvent()
                if event == streamEvent then
                    drafts[value] = reset and "" or (drafts[value] or "") .. tostring(piece or "")
                    local suffix = drafts[value]:match("^%s*([^%s]+)")
                    local completes = canCompleteCurrent and drafts[value] ~= "" and not drafts[value]:match("^%s")
                    suggestionCompletes[value] = completes
                    suggestions[value] = suffix and ((completes and suggestionPrefix or "") .. suffix) or nil
                    status = ("Suggest %d/3"):format(value)
                    renderSidebar()
                    renderSuggestions()
                elseif event == "peripheral" and peripheral.getType(value) == "monitor" then
                    reloadDisplay("Monitor connected")
                    status = "Suggesting..."
                    renderDisplay()
                elseif event == "peripheral_detach" and value == monitorName then
                    reloadDisplay("Monitor removed")
                    status = "Suggesting..."
                    renderDisplay()
                elseif event == "monitor_resize" and (value == monitorName or not usingMonitor) then
                    reloadDisplay("Monitor resized")
                    status = "Suggesting..."
                    renderDisplay()
                end
            end
        end)

    reloadDisplay("Suggestions ready")
    status = "Reloading OCR"
    renderDisplay()
    model = loadModel(mode == "letters" and letterModelPath or digitModelPath)
    if callOk and runOk and fs.exists(outputPath) then
        local handle = fs.open(outputPath, "r")
        local seen = {}
        suggestions = {}
        suggestionCompletes = {}
        while handle and #suggestions < 3 do
            local line = handle.readLine()
            if not line then break end
            local kind, word = line:match("^(%a+)\t(.*)$")
            if not kind then kind, word = "next", line end
            word = word:gsub("[%c%s]", "")
            local completes = canCompleteCurrent and kind == "complete"
            if completes then word = suggestionPrefix .. word end
            if word ~= "" and not seen[word] then
                seen[word] = true
                suggestions[#suggestions + 1] = word
                suggestionCompletes[#suggestions] = completes
            end
        end
        if handle then handle.close() end
        fs.delete(outputPath)
        status = #suggestions > 0 and "Pick suggestion" or "No suggestions"
    else
        if fs.exists(outputPath) then fs.delete(outputPath) end
        status = "Suggest failed"
    end
    renderDisplay()
end

local function acceptSuggestion(x)
    local totalWidth = sidebarX - 1
    local index = math.min(3, math.floor((x - 1) * 3 / totalWidth) + 1)
    local word = suggestions[index]
    if not word then return end
    if suggestionCompletes[index] and suggestionPrefix ~= "" then
        text = text:sub(1, #text - #suggestionPrefix) .. word .. " "
    else
        local separator = text:match("%s$") and "" or " "
        text = text .. separator .. word .. " "
    end
    response, suggestions = nil, {}
    status = "Added " .. word
    renderDisplay()
    os.queueEvent("draw_ocr_suggest")
end

renderDisplay()

running = true
while running do
    local event, button, x, y = os.pullEvent()
    if event == "mouse_click" then
        cancelAutoTimer()
        lastTouchX, lastTouchY = nil, nil
        if y == height - 1 and x < sidebarX then
            acceptSuggestion(x)
        elseif y == height and x > width - 8 then
            sendPrompt()
        elseif inside(x, y) then
            if response then response = nil; renderDisplay() end
            local enabled = button ~= 2
            setInk(x, y, enabled)
            lastX, lastY = x, y
        elseif x >= sidebarX then
            activateControl(y)
        end
    elseif event == "mouse_drag" and lastX then
        line(lastX, lastY, x, y, button ~= 2)
        lastX, lastY = x, y
    elseif event == "mouse_up" then
        local wasDrawing = lastX ~= nil
        lastX, lastY = nil, nil
        if wasDrawing then scheduleAutoRecognize() end
    elseif event == "monitor_touch" and usingMonitor and button == monitorName then
        cancelAutoTimer()
        if y == height - 1 and x < sidebarX then
            acceptSuggestion(x)
        elseif y == height and x > width - 8 then
            sendPrompt()
        elseif inside(x, y) then
            if response then response = nil; renderDisplay() end
            local enabled = not touchErase
            if lastTouchX and math.abs(x - lastTouchX) <= 8 and math.abs(y - lastTouchY) <= 8 then
                line(lastTouchX, lastTouchY, x, y, enabled)
            else
                setInk(x, y, enabled)
            end
            lastTouchX, lastTouchY = x, y
            touchTimer = os.startTimer(0.4)
        elseif x >= sidebarX then
            activateControl(y)
        end
    elseif event == "peripheral" and peripheral.getType(button) == "monitor" then
        reloadDisplay("Monitor connected")
    elseif event == "peripheral_detach" and button == monitorName then
        reloadDisplay("Monitor removed")
    elseif event == "monitor_resize" and (button == monitorName or not usingMonitor) then
        reloadDisplay("Monitor resized")
    elseif event == "key" then
        if button == keys.r then
            recognizeInk(); renderSidebar(); renderText()
        elseif button == keys.a then
            autoRecognize = not autoRecognize
            if not autoRecognize then cancelAutoTimer() end
            status = autoRecognize and "Auto enabled" or "Auto disabled"
            renderSidebar()
        elseif button == keys.m then
            toggleMode(); renderSidebar()
        elseif button == keys.c then response = nil; cancelAutoTimer(); clearInk(); status = "Ink cleared"; renderDisplay()
        elseif button == keys.enter then sendPrompt()
        elseif button == keys.q then running = false end
    elseif event == "timer" and button == autoTimer then
        autoTimer = nil
        recognizeInk(); renderSidebar(); renderText()
    elseif event == "timer" and button == touchTimer then
        touchTimer, lastTouchX, lastTouchY = nil, nil, nil
        if autoRecognize and next(ink) then recognizeInk(); renderSidebar(); renderText() end
    elseif event == "timer" and button == suggestionTimer then
        suggestionTimer = nil
        refreshSuggestions()
    elseif event == "draw_ocr_suggest" then
        refreshSuggestions()
    elseif event == "terminate" then running = false end
end

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
if usingMonitor then pcall(monitor.write, "Finished") end
term.redirect(nativeTerminal)
print("Recognized text: " .. text)
