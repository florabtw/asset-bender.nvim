local M = {}
local log = require('plenary.log').new({
    plugin = 'asset-bender',
    use_console = false
})

local path_join = require('bobrown101.plugin-utils').path_join;

local buffer_find_root_dir =
    require('bobrown101.plugin-utils').buffer_find_root_dir;

local is_dir = require('bobrown101.plugin-utils').is_dir;

local filetypes = require('asset-bender-filetypes').defaultConfig;

local uv = vim.loop

local current_project_roots = {}
local handle = nil
local pid = nil

local function has_value(tab, val)
    for index, value in ipairs(tab) do if value == val then return true end end
    return false
end

local function reduce_array(arr, fn, init)
    local acc = init
    for k, v in ipairs(arr) do
        if 1 == k and not init then
            acc = v
        else
            acc = fn(acc, v)
        end
    end
    return acc
end

local jobId = 0

function trimString(s) return s:match("^%s*(.-)%s*$") end

local function getLogPath() return vim.lsp.get_log_path() end

local function shutdownCurrentProcess()
    if (pid) then
        log.info('Shutting down current process: ' .. pid)
        uv.kill(-pid, uv.constants.SIGTERM)
        pid = nil
        handle = nil
    end
end

local function startAssetBenderProcess(rootsArray)
    log.info('Asset Bender starting new client')

    local baseArgs = {
        'reactor', 'host', '--host-most-recent', 100
    }

    local baseArgsWithWorkspaces = reduce_array(rootsArray,
                                                function(accumulator, current)
        table.insert(accumulator, current)
        return accumulator
    end, baseArgs)

    log.info('Starting NEW asset-bender with args, ' ..
                 vim.inspect(baseArgsWithWorkspaces))

    local function jobLogger(data)
        if (data ~= nil) then
            local prefix = 'asset-bender process #' .. jobId .. ' - '
            log.info(prefix .. vim.inspect(data))
        end
    end

    local stderr = uv.new_pipe()
    local stdout = uv.new_pipe()

    local handle, pid = uv.spawn('bend', {
        args = baseArgsWithWorkspaces,
        detached = true,
        stdio = { stdout, stderr }
    }, function(code, signal)
        log.info('Process exited with code, signal: ', code, signal)
    end)

    uv.read_start(stderr, function(err, data)
        assert(not err, err)
        if data then
            log.info(data)
        end
    end)

    uv.read_start(stdout, function(err, data)
        if data then
            log.info(data)
        end
    end)

    jobId = jobId + 1

    return handle, pid
end

function M.check_start_javascript_lsp()
    log.info('Checking if we need to start a process')
    local bufnr = vim.api.nvim_get_current_buf()

    -- Filter which files we are considering.
    if not filetypes[vim.api.nvim_buf_get_option(bufnr, 'filetype')] then
        return
    end

    -- Try to find our root directory. We will define this as a directory which contains
    -- .git. Another choice would be to check for `package.json`, or for `node_modules`.
    local root_dir = buffer_find_root_dir(bufnr, function(dir)
        -- return is_dir(path_join(dir, 'node_modules'))
        -- return vim.fn.filereadable(path_join(dir, 'package.json')) == 1
        return is_dir(path_join(dir, '.git'))
    end)

    -- We couldn't find a root directory, so ignore this file.
    if not root_dir then
        log.info('we couldnt find a root directory, ending')
        return
    end

    -- if the current root_dir is not in the current_project_roots, then we must stop the current process and start a new one with the new root
    if (not has_value(current_project_roots, root_dir)) then
        log.info(
            'asset-bender.nvim - detected new root, shutting down current process and starting another')

        shutdownCurrentProcess()

        table.insert(current_project_roots, root_dir)

        handle, pid = startAssetBenderProcess(current_project_roots);

        log.info('started new process: ', pid)
    end
end

local function setupAutocommands()
    log.info('setting up autocommands')
    local group = vim.api.nvim_create_augroup("asset-bender.nvim",
                                              {clear = true})

    log.info('group created')
    vim.api.nvim_create_autocmd("BufReadPost", {
        group = group,
        desc = "asset-bender.nvim will check if it needs to start a new process on the BufReadPost event",
        callback = function()
            local data = {
                buf = vim.fn.expand("<abuf>"),
                file = vim.fn.expand("<afile>"),
                match = vim.fn.expand("<amatch>")
            }
            vim.schedule(function() M.check_start_javascript_lsp() end)
        end
    })

    vim.api.nvim_create_autocmd('VimLeavePre', {
        group = group,
        callback = function()
            vim.schedule(M.stop)
        end
    })

    log.info('autocommand created')
    log.info('Asset bender plugin intialized')
end

function M.stop()
    shutdownCurrentProcess()
end

function M.setup() setupAutocommands() end

function M.reset()
    log.info(
        '"reset" called - running LspStop, cancelling current asset-bender process, resetting roots, and running LspStart')
    vim.cmd('LspStop')
    current_project_roots = {}
    shutdownCurrentProcess()
    vim.cmd('LspStart')
    print(
        'Open a new file, or re-open an existing one with ":e" for asset-bender.nvim to start a new process')
end

return M
