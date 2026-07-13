--- Word count utilities — count words, sentences, paragraphs, sections from
--- buffer text, and format the results for the modeline display.
---
--- Performance: uses a single-pass line-by-line scan of the buffer (avoids
--- concatenating the whole buffer text) and caches results via
--- `buffer.lsp_version` so repeated calls with no changes are instant.

---@diagnostic disable: lowercase-global, unused-local, inject-field

local M = {}

---@class WordCountStats
---@field words integer
---@field sentences integer
---@field paragraphs integer
---@field sections integer
---@field chars integer
---@field _lsp_version integer|nil cache busting key

--- Count statistics for a buffer in a single pass (line-by-line).
--- Avoids concatenating the whole buffer into one string.
--- Pass `line_count` and a line-text accessor function.
---
--- The accessor `line_fn(i)` returns the text of line i (including
--- trailing newline, matching buffer semantics). Returns nil past end.
---@param line_count integer
---@param line_fn function
---@return WordCountStats
function M.count_buffer(line_count, line_fn)
	if line_count == 0 then
		return { words = 0, sentences = 0, paragraphs = 0, sections = 0, chars = 0, _lsp_version = nil }
	end

	local words = 0
	local sentences = 0
	local paragraphs = 0
	local sections = 0
	local chars = 0

	local in_para = false
	-- Does the previous non-blank line end with [.!?] at its own newline?
	-- (The sentence `gsub` can't see that because we strip the newline, so
	-- we track it here and add the sentence when the next non-blank line arrives.)
	local pending_eol_sentence = false

	for i = 0, line_count - 1 do
		local text = line_fn(i)
		if text == nil then
			break
		end
		local line_len = #text
		chars = chars + line_len

		-- Strip trailing newline for content analysis.
		local content = text
		if line_len > 0 and text:byte(line_len) == 10 then
			content = text:sub(1, line_len - 1)
		end

		local is_blank = content:match("^%s*$") ~= nil

		--- Paragraph boundary
		if is_blank then
			in_para = false
			-- If the PREVIOUS line ended with [.!?] and the next line
			-- is blank, the sentence is complete (sentence boundary was
			-- at the previous line's EOL). Count it now.
			if pending_eol_sentence then
				sentences = sentences + 1
				pending_eol_sentence = false
			end
		else
			-- Paragraph start.
			if not in_para then
				paragraphs = paragraphs + 1
				in_para = true
			end

			-- Words: whitespace-delimited tokens.
			local _, nw = content:gsub("%S+", "")
			words = words + nw

			-- Sentences ending with [.!?] followed by space or newline.
			-- (The newline case catches mid-line newlines from
			-- concatenated buffer text; for line-by-line iteration the
			-- newline is stripped, so only the space case fires here.)
			local _, ns = content:gsub("[.!?][ \n]", "")
			sentences = sentences + ns

			-- Cross-line sentence: previous line ended with [.!?] at its
			-- own newline, so THIS line's first non-whitespace content
			-- continues that sentence. The sentence boundary was crossed
			-- at the newline.
			if pending_eol_sentence then
				sentences = sentences + 1
				pending_eol_sentence = false
			end

			-- Does THIS line end with sentence-ending punctuation at
			-- its own newline? i.e. the content (with newline stripped)
			-- ends with [.!?]. This means a sentence boundary falls on
			-- the line boundary, and the next non-blank line gets +1.
			if content:match("[.!?]$") then
				pending_eol_sentence = true
			end

			-- Sections: markdown headings.
			if content:match("^#+ ") then
				sections = sections + 1
			end
		end
	end

	-- After the loop: if the last non-blank line ended with [.!?] at
	-- its own newline (and there IS no next line), that final period
	-- ends a sentence that the gsub couldn't see.
	if pending_eol_sentence then
		sentences = sentences + 1
	end

	return {
		words = words,
		sentences = sentences,
		paragraphs = paragraphs,
		sections = sections,
		chars = chars,
		_lsp_version = nil,
	}
end

--- Get the text between two (line, col) pairs.
--- Bypasses the buffer concatenation to avoid large string allocation.
--- Used by selection-aware counting.
---@param view View
---@param sl integer start line
---@param sc integer start col
---@param el integer end line
---@param ec integer end col
---@return string
local function get_region_text(view, sl, sc, el, ec)
	---@cast sc integer
	---@cast el integer
	---@cast ec integer
	return view:text_between(sl, sc, el, ec)
end

--- Compute stats for a view (selection or whole buffer).
--- Caches the result on `view._wc_cache` and busts it when
--- `buffer.lsp_version` changes.
---@param view View
---@return WordCountStats
function M.compute(view)
	local buf = view.buffer
	local lsp_ver = buf and buf.lsp_version

	-- Return cached result if nothing changed (same buffer, same lsp_version).
	-- The buffer identity check guards against buffer swaps where the
	-- new buffer happens to share the same lsp_version.
	if view._wc_cache and view._wc_cache._buf == buf and view._wc_cache._lsp_version == lsp_ver then
		return view._wc_cache
	end

	local stats
	if view:has_selection() then
		local sl, sc, el, ec = view:selection_range()
		local text = get_region_text(view, sl, sc, el, ec)
		stats = M.count_buffer(1, function(i)
			if i == 0 then
				return text
			end
			return nil
		end)
	else
		local n = buf:line_count()
		stats = M.count_buffer(n, function(i)
			return buf:line_text(i)
		end)
	end

	stats._lsp_version = lsp_ver
	stats._buf = buf
	view._wc_cache = stats
	return stats
end

--- Invalidate the word-count cache for a view.
---@param view View
function M.invalidate(view)
	view._wc_cache = nil
end

--- Format stats for the modeline display.
---@param stats WordCountStats
---@param goals? { total: integer?, increment: integer?, start_words: integer? }
---@return string
function M.format(stats, goals)
	local parts = {}

	-- Core stats: words, sentences, paragraphs, sections, pages, reading time.
	parts[#parts + 1] = stats.words .. "w"
	if stats.sentences > 0 then
		parts[#parts + 1] = stats.sentences .. "s"
	end
	parts[#parts + 1] = stats.paragraphs .. "¶"
	if stats.sections > 0 then
		parts[#parts + 1] = stats.sections .. "§"
	end

	-- Estimated pages (250 words/page) and reading time (200 wpm).
	local pages = math.ceil(stats.words / 250)
	local read_min = math.ceil(stats.words / 200)
	parts[#parts + 1] = "~" .. pages .. "pg"
	if read_min <= 1 then
		parts[#parts + 1] = "<1m"
	else
		parts[#parts + 1] = "~" .. read_min .. "m"
	end

	local base = table.concat(parts, " ")

	-- Goal progress (shown first when goals are set).
	if goals and (goals.total or goals.increment) then
		local goal_parts = {}
		if goals.total then
			local pct = math.floor(stats.words / goals.total * 100)
			goal_parts[#goal_parts + 1] = stats.words .. "→" .. goals.total .. " (" .. pct .. "%)"
		end
		if goals.increment and goals.start_words then
			local written = stats.words - goals.start_words
			if written < 0 then
				written = 0
			end
			local pct = math.floor(written / goals.increment * 100)
			goal_parts[#goal_parts + 1] = "+" .. written .. "→+" .. goals.increment .. " (" .. pct .. "%)"
		end
		return table.concat(goal_parts, " ") .. "  " .. base
	end

	return base
end

return M
