local TARGET_FAMILY = ya.target_family()

-- == Helpers ==================================================================

---@param path string
---@return string?
local function read_text(path)
    local f = io.open(path, 'r')
    if not f then
        return nil
    end

    local text = f:read('*a')
    f:close()
    return text
end

--- @param path string
--- @return string[]|nil
local function read_lines(path)
    local text = read_text(path)
    if not text then
        return nil
    end

    local lines = {}
    for line in text:gmatch('([^\r\n]*)') do
        table.insert(lines, line)
    end
    return lines
end

--- @param path string
--- @return Status?
local function rmdir(path)
    local status, err
    if TARGET_FAMILY == 'windows' then
        status, err =
            Command('powershell'):arg({ '-NoProfile', '-Command', string.format("rmdir '%s'", path) }):status()
    else
        status, err = Command('rmdir'):arg({ path }):status()
    end

    if not status then
        ya.err(string.format('rmdir error: %s', tostring(err)))
    end

    return status
end

local Utf16leToUtf8 = {}

--- @return ('lua'|'iconv'|'powershell')
function Utf16leToUtf8.method()
    if Command('iconv'):status() then
        return 'iconv'
    elseif Command('powershell'):status() then
        return 'powershell'
    else
        return 'lua'
    end
end

--- Gemini 생성
--- @param data string UTF-16LE 문자열
--- @return string UTF-8 문자열
function Utf16leToUtf8.convert_text(data)
    -- 결과 UTF-8 문자열을 저장할 테이블
    local result = {}
    local len = #data
    local i = 1

    -- 1. BOM (Byte Order Mark) 처리
    local BOM_LE = string.char(0xFF, 0xFE) -- UTF-16LE BOM 바이트 시퀀스
    if len >= 2 and string.sub(data, 1, 2) == BOM_LE then
        i = 3 -- BOM을 건너뛰고 세 번째 바이트부터 시작
    end

    -- 2. UTF-16 바이트 시퀀스를 코드 포인트로 변환 (2바이트씩)
    while i <= len - 1 do
        -- UTF-16LE는 Little Endian (낮은 바이트가 먼저)
        local B1 = string.byte(data, i)
        local B2 = string.byte(data, i + 1)
        local code_unit = (B2 << 8) | B1 -- B2 (High Byte)를 8비트 왼쪽 시프트 후 B1 (Low Byte)과 OR 연산
        i = i + 2 -- 다음 2바이트로 이동

        local codepoint

        -- 서로게이트 쌍 범위 확인 (U+D800 to U+DFFF)
        if code_unit >= 0xD800 and code_unit <= 0xDBFF then
            -- High Surrogate (상위 서로게이트)
            if i <= len - 1 then
                -- 다음 2바이트를 Low Surrogate로 읽음
                local L1 = string.byte(data, i)
                local L2 = string.byte(data, i + 1)
                local low_unit = (L2 << 8) | L1
                i = i + 2

                if low_unit >= 0xDC00 and low_unit <= 0xDFFF then
                    -- Low Surrogate (하위 서로게이트)와 결합하여 코드 포인트를 계산합니다.
                    -- codepoint = 0x10000 + (H - 0xD800) * 0x400 + (L - 0xDC00)
                    local H = code_unit - 0xD800 -- 0x0000 to 0x03FF (10 bits)
                    local L = low_unit - 0xDC00 -- 0x0000 to 0x03FF (10 bits)
                    codepoint = 0x10000 + (H << 10) + L
                else
                    -- 유효하지 않은 Low Surrogate (대체 문자로 처리)
                    codepoint = 0xFFFD
                end
            else
                -- 파일 끝에 High Surrogate만 있음 (대체 문자로 처리)
                codepoint = 0xFFFD
            end
        elseif code_unit >= 0xDC00 and code_unit <= 0xDFFF then
            -- Low Surrogate가 단독으로 나타남 (대체 문자로 처리)
            codepoint = 0xFFFD
        else
            -- BMP (Basic Multilingual Plane) 문자: 코드 단위 자체가 코드 포인트
            codepoint = code_unit
        end

        -- 3. 코드 포인트(숫자)를 UTF-8 바이트 시퀀스로 변환
        if codepoint < 0x80 then
            -- 1바이트 (0xxxxxxx)
            table.insert(result, string.char(codepoint))
        elseif codepoint < 0x800 then
            -- 2바이트 (110xxxxx 10xxxxxx)
            local b1 = 0xC0 | (codepoint >> 6)
            local b2 = 0x80 | (codepoint & 0x3F)
            table.insert(result, string.char(b1, b2))
        elseif codepoint < 0x10000 then
            -- 3바이트 (1110xxxx 10xxxxxx 10xxxxxx)
            local b1 = 0xE0 | (codepoint >> 12)
            local b2 = 0x80 | ((codepoint >> 6) & 0x3F)
            local b3 = 0x80 | (codepoint & 0x3F)
            table.insert(result, string.char(b1, b2, b3))
        elseif codepoint < 0x110000 then
            -- 4바이트 (11110xxx 10xxxxxx 10xxxxxx 10xxxxxx)
            local b1 = 0xF0 | (codepoint >> 18)
            local b2 = 0x80 | ((codepoint >> 12) & 0x3F)
            local b3 = 0x80 | ((codepoint >> 6) & 0x3F)
            local b4 = 0x80 | (codepoint & 0x3F)
            table.insert(result, string.char(b1, b2, b3, b4))
        else
            -- 유효하지 않거나 범위를 벗어난 코드 포인트 (대체 문자 U+FFFD)
            table.insert(result, string.char(0xEF, 0xBF, 0xBD))
        end
    end

    -- 테이블의 모든 UTF-8 문자열을 하나로 연결하여 최종 문자열 반환
    return table.concat(result)
end

--- @param path string
function Utf16leToUtf8:convert_lua(path)
    local text = read_text(path)
    if not text then
        return false
    end

    text = self.convert_text(text)
    local f = io.open(path, 'w')
    if not f then
        return false
    end

    f:write(text)
    f:close()

    return true
end

--- @param path string
--- @param method string
function Utf16leToUtf8.convert_command(path, method)
    local args
    if method == 'iconv' then
        -- XXX 테스트 필요
        args = { '-f', 'UTF-16LE', '-t', 'UTF-8', path, '-o', path }
    elseif method == 'powershell' then
        -- lua 함수 사용한 변환이 더 빠름
        local cmd = "(Get-Content -Path '%s' -Encoding Unicode) | Set-Content -Path '%s' -Encoding Utf8"
        args = {
            '-NoProfile',
            '-Command',
            string.format(cmd, path, path),
        }
    else
        error('Unknown method: ' .. method)
    end

    local status, err = Command(method):arg(args):status()
    if not status then
        ya.err(string.format('%s error: %s', method, tostring(err)))
    end

    return not not status
end

--- @param path string
--- @param method ('lua'|'iconv'|'powershell'|nil)
function Utf16leToUtf8:convert(path, method)
    method = method == nil and 'lua' or self.method()
    ya.dbg('convert method: ' .. method)

    if method == 'iconv' or method == 'powershell' then
        self.convert_command(path, method)
    end

    self:convert_lua(path)
end

-- == Cache ====================================================================
--- @class HwpCache
--- @field public cache Url ya.file_cache(job)로 생성한 경로. 압축을 풀 임시 폴더로 사용
--- @field public image Url
--- @field public text Url
--- @field public update boolean

--- @class HwpPreview
--- @field public image string
--- @field public text string

--- @class HwpFile
--- @field public file File
--- @field public type ('hwp'|'hwpx')
--- @field public cache HwpCache
--- @field public preview HwpPreview

--- @param file File
--- @param cache Url
--- @return HwpCache
local function init_hwp_cache(file, cache)
    local image = Url(tostring(cache) .. '-image')
    local text = Url(tostring(cache) .. '-text')

    local img = fs.cha(image)
    local txt = fs.cha(text)
    local mtime = math.min(img and img.mtime or 0, txt and txt.mtime or 0)

    return {
        cache = cache,
        image = image,
        text = text,
        update = mtime < file.cha.mtime,
    }
end

--- @param job { file: File, skip: integer }
--- @return HwpFile?
local function init_hwp_file(job)
    local cache = ya.file_cache(job)
    if not cache then
        return nil
    end

    local file_type
    if job.file.name:sub(-5):lower() == '.hwpx' then
        file_type = 'hwpx'
    elseif job.file.name:sub(-4):lower() == '.hwp' then
        file_type = 'hwp'
    else
        ya.err('Unknown extension: ' .. job.file.name)
        return nil
    end

    local preview = {
        image = file_type == 'hwpx' and 'Preview/PrvImage.png' or 'PrvImage',
        text = file_type == 'hwpx' and 'Preview/PrvText.txt' or 'PrvText',
    }

    return {
        file = job.file,
        type = file_type,
        cache = init_hwp_cache(job.file, cache),
        preview = preview,
    }
end

--- @param hwp HwpFile
--- @return boolean
local function extract_preview(hwp)
    local cache_dir = tostring(hwp.cache.cache)
    local args = { 'e', tostring(hwp.file.url), string.format('-o%s', cache_dir) }
    for _, preview in pairs(hwp.preview) do
        table.insert(args, preview)
    end

    local status, err = Command('7z'):arg(args):status()
    if not status or not status.success then
        ya.err(string.format('7z error: %s', tostring(err)))
        return false
    end

    for _, key in ipairs({ 'image', 'text' }) do
        local cache = tostring(hwp.cache[key])
        local preview = Url(hwp.preview[key]).name
        local extracted = Url(string.format('%s/%s', cache_dir, preview))
        if not fs.cha(extracted) then
            ya.err('Failed to extract preview: ' .. preview)
            return false
        end

        os.remove(cache)
        os.rename(tostring(extracted), cache)
    end

    rmdir(cache_dir)
    return true
end

-- == Preview Module ==================================================================
local M = {}

--- @class Option
--- @field orientation ('horizontal'|'vertical') 이미지와 텍스트 배치
--- @field max_image_ratio number
--- @field text_wrap ui.Wrap

local get_option = ya.sync(function(st)
    --- @type Option
    local opts = st.opts
    local text_wrap = (opts and opts.text_wrap ~= nil) and opts.text_wrap or ui.Wrap.YES
    return {
        orientation = opts and opts.orientation or 'horizontal',
        max_image_ratio = opts and opts.max_image_ratio or 0.75,
        text_wrap = text_wrap,
    }
end)

--- @param opts { orientation: ('horizontal'|'vertical'|nil), max_image_ratio: number?, text_wrap: boolean?}
function M:setup(opts)
    local wrap = (opts and opts.text_wrap ~= nil) and opts.text_wrap or true

    --- @type Option
    self.opts = {
        orientation = opts and opts.orientation or 'horizontal',
        max_image_ratio = opts and opts.max_image_ratio or 0.75,
        text_wrap = wrap and ui.Wrap.YES or ui.Wrap.NO,
    }
end

--- @param job { file: File, skip: integer }
--- @return boolean
function M:preload(job)
    local hwp = init_hwp_file(job)

    if not hwp then
        return false
    end
    if not hwp.cache.update then
        -- 캐시가 이미 존재
        return true
    end

    -- preview 추출
    if not extract_preview(hwp) then
        ya.err('Failed to generate preview: ' .. tostring(hwp.file.url))
        return false
    end

    local cha = { image = fs.cha(hwp.cache.image), text = fs.cha(hwp.cache.text) }
    if hwp.type == 'hwp' and cha.text then
        Utf16leToUtf8:convert(tostring(hwp.cache.text))
    end

    return not not (cha.image and cha.text)
end

--- @param job { area: ui.Rect, file: File, mime: string, skip: integer }
--- @return boolean
function M:peek(job)
    local start = os.clock()
    local hwp = init_hwp_file(job)

    if not hwp then
        return false
    end
    if not M:preload(job) then
        return false
    end

    --- @type Option
    local opt = get_option()

    ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))

    -- Image preview
    local rendered = hwp.cache.image
        and fs.cha(hwp.cache.image)
        and ya.image_show(
            hwp.cache.image,
            ui.Rect({
                x = job.area.x,
                y = job.area.y,
                w = job.area.w * opt.max_image_ratio,
                h = job.area.h * opt.max_image_ratio,
            })
        )

    -- Text preview
    local lines = read_lines(tostring(hwp.cache.text))
    if not lines or #lines == 0 then
        return true
    end

    local rect
    if opt.orientation == 'horizontal' then
        local w = rendered and rendered.w or 0
        rect = {
            x = job.area.x + w + 1,
            y = job.area.y,
            w = job.area.w - w - 1,
            h = job.area.h,
        }
    else
        local h = rendered and rendered.h or 0
        rect = {
            x = job.area.x,
            y = job.area.y + h,
            w = job.area.w,
            h = job.area.h - h,
        }
    end
    ya.preview_widget(job, ui.Text(lines):area(ui.Rect(rect)):wrap(opt.text_wrap))

    return true
end

return M
