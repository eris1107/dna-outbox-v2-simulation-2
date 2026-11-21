-- DNA V2 OUTBOX SIMULATION ONLY: no HTTP, game listeners, or real scoring.
-- Uses the same sender implementation as the V2 test logger with separate files.
local HttpService = game:GetService('HttpService')
local Players = game:GetService('Players')
local disposed = false
local masterEnabled = true
local enabled = false
local activeUrl = 'https://dna-test.invalid/api/hooks/999/LOCAL_SIMULATION'
local simulationOnline = false
local simulationReceiptFile = 'dna_simulated_server_receipts_v2.json'
local gui = Instance.new('ScreenGui')
gui.Name = 'DNAOutboxV2Simulation'
gui.ResetOnSpawn = false
local parent = Players.LocalPlayer:WaitForChild('PlayerGui')
if parent:FindFirstChild(gui.Name) then
    error('Panel simulasi sudah berjalan. Jangan jalankan dua salinan bersamaan.')
end
local frame = Instance.new('Frame')
frame.Size = UDim2.new(0.9,0,0,350)
frame.Position = UDim2.new(0.05,0,0.1,0)
frame.BackgroundColor3 = Color3.fromRGB(18,29,48)
frame.Parent = gui
local status = Instance.new('TextLabel')
status.Size = UDim2.new(1,-24,0,155)
status.Position = UDim2.fromOffset(12,10)
status.BackgroundTransparency = 1
status.TextColor3 = Color3.fromRGB(225,245,240)
status.TextSize = 15
status.TextWrapped = true
status.TextXAlignment = Enum.TextXAlignment.Left
status.TextYAlignment = Enum.TextYAlignment.Top
status.Text = 'SIMULASI ANTREAN V2. Tidak ada HTTP atau data game. Memeriksa file...'
status.Parent = frame
local function setDeliveryStatus(text)
    if status.Parent then status.Text = 'SIMULASI SAJA, BUKAN SERVER DNA\n' .. text end
end
local function transport()
    -- Explicitly a local fake server; no fallback to real network functions.
    return function(options)
        if not simulationOnline then
            return {StatusCode=503, Body='{"error":"Koneksi simulasi OFF"}'}
        end
        local body = HttpService:JSONDecode(options.Body)
        local receipts = {}
        if isfile(simulationReceiptFile) then
            receipts = HttpService:JSONDecode(readfile(simulationReceiptFile))
            assert(type(receipts)=='table','File receipt simulasi rusak')
        end
        local response = {protocol='DNA_DELIVERY_V2',results={}}
        for _, item in ipairs(body.catches or {}) do
            local result = {event_id=item.event_id}
            if item.nama_pemain == 'SIMULATED_UNKNOWN_PLAYER' then
                result.status='rejected'
                result.error='Pemain simulasi sengaja tidak terdaftar'
            elseif receipts[item.event_id] then
                result.status='duplicate'
            else
                receipts[item.event_id]=true
                result.status='accepted'
            end
            table.insert(response.results,result)
        end
        local encoded=HttpService:JSONEncode(receipts)
        writefile(simulationReceiptFile,encoded)
        assert(readfile(simulationReceiptFile)==encoded,'Receipt simulasi belum terverifikasi')
        return {StatusCode=200,Body=HttpService:JSONEncode(response)}
    end
end

-- DNA delivery v2 TEST: local outbox, two verified rotating snapshots.
-- Requires server protocol DNA_DELIVERY_V2. Does not implement late-session scoring.
-- Run only ONE logger instance per device/workspace.
local OUTBOX_FILES = {"dna_simulated_outbox_v2_a.json", "dna_simulated_outbox_v2_b.json"}
local OUTBOX_LIMIT = 20000
local MAX_SNAPSHOT_BYTES = 12 * 1024 * 1024
local ledger = {version = 2, sequence = 0, jobs = {}, confirmed = 0, rejected = 0}
local ledgerLoaded = false
local ledgerBusy = false
local storageHealthy = false
local storageNotice = "Belum diperiksa"
local captureFailures = 0
local batchLimit = 50

local function destinationOf(url)
    if type(url) ~= "string" then return nil end
    -- Save account destination ONLY, never the webhook token.
    return url:match("^(https://[^/]+/api/hooks/%d+)/[^/?#%s]+$")
end

local function lockLedger()
    while ledgerBusy do task.wait(0.02) end
    ledgerBusy = true
end

local function unlockLedger()
    ledgerBusy = false
end

local function countJobs()
    local pending, held = 0, 0
    for _, job in ipairs(ledger.jobs) do
        if job.state == "pending" then pending = pending + 1 else held = held + 1 end
    end
    return pending, held
end

local function showLedger(note)
    local pending, held = countJobs()
    setDeliveryStatus((note or "") .. " | menunggu " .. pending
        .. "; ditahan " .. held .. "; konfirmasi " .. ledger.confirmed
        .. "; gagal masuk antrean " .. captureFailures
        .. (storageHealthy and " | file OK" or " | FILE BERMASALAH: " .. storageNotice))
end

local function validLedger(value)
    if type(value) ~= "table" or value.version ~= 2
        or type(value.sequence) ~= "number" or value.sequence < 0
        or value.sequence % 1 ~= 0 or type(value.jobs) ~= "table"
        or #value.jobs > OUTBOX_LIMIT then return false end
    local seen = {}
    for _, job in ipairs(value.jobs) do
        if type(job) ~= "table" or type(job.id) ~= "string"
            or job.id == "" or #job.id > 200 or seen[job.id]
            or type(job.destination) ~= "string"
            or not job.destination:match("^https://[^/]+/api/hooks/%d+$")
            or type(job.payload) ~= "table"
            or job.payload.event_id ~= job.id
            or (job.state ~= "pending" and job.state ~= "rejected") then return false end
        seen[job.id] = true
    end
    return true
end

-- Call with ledger lock held. Both snapshots are initialized before any sends.
local function persistLedger()
    local candidate = {
        version = 2, sequence = ledger.sequence + 1, jobs = ledger.jobs,
        confirmed = ledger.confirmed, rejected = ledger.rejected,
    }
    local ok, problem = pcall(function()
        local encoded = HttpService:JSONEncode(candidate)
        if #encoded > MAX_SNAPSHOT_BYTES then error("OUTBOX_SIZE_LIMIT") end
        local slot = candidate.sequence % 2 + 1
        writefile(OUTBOX_FILES[slot], encoded)
        if readfile(OUTBOX_FILES[slot]) ~= encoded then error("READBACK_MISMATCH") end
        ledger.sequence = candidate.sequence
    end)
    storageHealthy = ok
    storageNotice = ok and "OK" or "Tulis/verifikasi file gagal; pengiriman dijeda"
    return ok
end

local function loadLedger()
    if type(readfile) ~= "function" or type(writefile) ~= "function"
        or type(isfile) ~= "function" then
        storageNotice = "Perlu readfile, writefile dan isfile; tidak beralih diam-diam ke memori"
        return false
    end
    local candidates = {}
    local anyExists = false
    for _, name in ipairs(OUTBOX_FILES) do
        local existsOK, exists = pcall(isfile, name)
        if not existsOK then storageNotice = "Pemeriksaan file gagal"; return false end
        if exists then
            anyExists = true
            local ok, value = pcall(function()
                local text = readfile(name)
                if #text > MAX_SNAPSHOT_BYTES then error("FILE_TOO_LARGE") end
                return HttpService:JSONDecode(text)
            end)
            if ok and validLedger(value) then table.insert(candidates, value) end
        end
    end
    if anyExists and #candidates == 0 then
        storageNotice = "Kedua snapshot tidak dapat dibaca; jangan hapus file"
        return false
    end
    if #candidates > 0 then
        table.sort(candidates, function(a,b) return a.sequence > b.sequence end)
        ledger = candidates[1]
        ledger.confirmed = tonumber(ledger.confirmed) or 0
        ledger.rejected = tonumber(ledger.rejected) or 0
        for _, job in ipairs(ledger.jobs) do job.readyAt = 0 end
    end
    ledgerLoaded = true
    -- Verify that recovery AND fresh writes work before starting HTTP.
    if not persistLedger() then return false end
    if not persistLedger() then return false end
    return true
end

local function ensureLedger()
    if not ledgerLoaded then return loadLedger() end
    if not storageHealthy then return persistLedger() end
    return true
end

local function safeReason(value)
    -- Reason is shown locally; URLs and credentials are never included intentionally.
    local text = tostring(value or "Tanpa alasan")
    text = text:gsub("https?://%S+", "[URL disembunyikan]")
    return text:sub(1, 180)
end

local function postContent(url, content, isTest, catchPayload)
    if disposed or not masterEnabled then
        setDeliveryStatus("Koneksi utama OFF; belum merekam tangkapan baru.")
        return
    end
    local destination = destinationOf(url)
    if not destination then
        captureFailures = captureFailures + (isTest and 0 or 1)
        setDeliveryStatus("Gunakan URL DNA /api/hooks/nomor/token. Token jangan dibagikan.")
        return
    end
    if isTest then
        task.spawn(function()
            local ok, response = pcall(function()
                local sender = transport()
                if not sender then error("NO_TRANSPORT") end
                return sender({Url = url, Method = "POST",
                    Headers = {["Content-Type"] = "application/json"},
                    Body = HttpService:JSONEncode({content = content})})
            end)
            local code = ok and type(response) == "table"
                and tonumber(response.StatusCode or response.Status) or nil
            showLedger("Tes HTTP " .. tostring(code or "gagal") .. "; bukan bukti tangkapan tersimpan")
        end)
        return
    end
    if type(catchPayload) ~= "table" then
        captureFailures = captureFailures + 1
        showLedger("Payload tidak valid; belum diantrekan")
        return
    end
    catchPayload.event_id = catchPayload.event_id or HttpService:GenerateGUID(false)
    lockLedger()
    local ready = ensureLedger()
    if not ready or #ledger.jobs >= OUTBOX_LIMIT then
        captureFailures = captureFailures + 1
        showLedger(ready and "BATAS antrean tercapai; tangkapan ini belum disimpan" or "FILE gagal; tangkapan ini belum disimpan")
        unlockLedger()
        return
    end
    table.insert(ledger.jobs, {
        id = catchPayload.event_id, destination = destination,
        payload = catchPayload, state = "pending", attempts = 0, readyAt = 0,
    })
    local saved = persistLedger()
    showLedger(saved and "Tangkapan disimpan ke antrean file" or "Tangkapan baru masih di memori; jangan tutup")
    unlockLedger()
end

-- One worker, with network outside the file lock.
task.spawn(function()
    lockLedger()
    ensureLedger()
    showLedger("Outbox diperiksa; aktifkan koneksi dan kirim untuk melanjutkan")
    unlockLedger()
    while not disposed do
        local jobs = {}
        local requestUrl = nil
        if masterEnabled and enabled and activeUrl then
            lockLedger()
            if ensureLedger() then
                local destination = destinationOf(activeUrl)
                requestUrl = activeUrl
                for _, job in ipairs(ledger.jobs) do
                    if job.state == "pending" and job.destination == destination
                        and (tonumber(job.readyAt) or 0) <= os.time() and #jobs < batchLimit then
                        table.insert(jobs, job)
                    end
                end
            end
            unlockLedger()
        end
        if #jobs == 0 then
            task.wait(0.2)
        else
            local catches = {}
            for _, job in ipairs(jobs) do table.insert(catches, job.payload) end
            local ok, response = pcall(function()
                local sender = transport()
                if not sender then error("NO_TRANSPORT") end
                return sender({Url = requestUrl, Method = "POST",
                    Headers = {["Content-Type"] = "application/json"},
                    Body = HttpService:JSONEncode({catches = catches})})
            end)
            local code = ok and type(response) == "table"
                and tonumber(response.StatusCode or response.Status) or nil
            local decoded = nil
            if ok and type(response) == "table" and type(response.Body) == "string" then
                local parsed, value = pcall(function() return HttpService:JSONDecode(response.Body) end)
                if parsed and type(value) == "table" then decoded = value end
            end
            lockLedger()
            local resultsById = {}
            local protocolOK = code and code >= 200 and code < 300 and decoded
                and decoded.protocol == "DNA_DELIVERY_V2" and type(decoded.results) == "table"
            if protocolOK then
                -- Duplicate response IDs invalidate that ID's acknowledgement.
                for _, result in ipairs(decoded.results) do
                    if type(result) == "table" and type(result.event_id) == "string" then
                        if resultsById[result.event_id] ~= nil then
                            resultsById[result.event_id] = false
                        else
                            resultsById[result.event_id] = result
                        end
                    end
                end
            end
            local completed = {}
            local lastReason = ""
            for _, job in ipairs(jobs) do
                local result = protocolOK and resultsById[job.id] or nil
                if result and (result.status == "accepted" or result.status == "duplicate") then
                    completed[job.id] = true
                    ledger.confirmed = ledger.confirmed + 1
                elseif result and (result.status == "rejected" or result.status == "ignored") then
                    -- Keep rejected payloads for audit/correction. Never count them as scored.
                    job.state = "rejected"
                    job.reason = safeReason(result.error or result.code)
                    ledger.rejected = ledger.rejected + 1
                    lastReason = job.reason
                else
                    job.attempts = (tonumber(job.attempts) or 0) + 1
                    job.readyAt = os.time() + math.min(30, 2 ^ math.min(job.attempts, 5)) + math.random(0, 2)
                    if result then lastReason = safeReason(result.error or result.code) end
                end
            end
            for i = #ledger.jobs, 1, -1 do
                if completed[ledger.jobs[i].id] then table.remove(ledger.jobs, i) end
            end
            local saved = persistLedger()
            if not saved then
                showLedger("Konfirmasi belum tersimpan ke file; HTTP dijeda sampai file pulih")
            elseif not protocolOK then
                showLedger("HTTP " .. tostring(code or "gagal koneksi") .. "; perlu server V2; antrean dipertahankan")
            else
                showLedger(lastReason ~= "" and ("Ditahan: " .. lastReason) or "Hasil tiap tangkapan diproses")
            end
            unlockLedger()
        end
    end
end)


local controlBusy = false
local function control(text, y, callback)
    local b=Instance.new('TextButton')
    b.Size=UDim2.new(1,-24,0,32)
    b.Position=UDim2.fromOffset(12,y)
    b.Text=text
    b.TextSize=14
    b.Parent=frame
    b.Activated:Connect(function()
        if controlBusy then return end
        controlBusy=true
        local ok,err=pcall(callback)
        if not ok then setDeliveryStatus('TES ERROR: '..tostring(err):sub(1,200)) end
        controlBusy=false
    end)
end
control('1. Simpan 3 tangkapan contoh (pengiriman masih OFF)',175,function()
    enabled=false
    simulationOnline=false
    for i=1,3 do
        postContent(activeUrl,'',false,{
            nama_pemain=i==3 and 'SIMULATED_UNKNOWN_PLAYER' or 'SIMULATED_VALID_PLAYER',
            nama_ikan='Ikan contoh, bukan tangkapan game',kelangkaan='Secret',
            mutasi='',big=false,shiny=false,
        })
    end
end)
control('2. Lihat antrean dari file (tidak mengirim)',213,function()
    lockLedger()
    ensureLedger()
    showLedger('Status antrean simulasi; tidak ada file yang dihapus')
    unlockLedger()
end)
control('3. Aktifkan server SIMULASI dan kirim antrean',251,function()
    simulationOnline=true
    enabled=true
    showLedger('Pengiriman simulasi ON; tunggu hasil per entri')
end)
control('4. Putuskan koneksi SIMULASI',289,function()
    simulationOnline=false
    showLedger('Koneksi simulasi OFF; percobaan berikutnya mendapat 503')
end)
gui.Destroying:Connect(function() disposed=true end)
gui.Parent=parent
