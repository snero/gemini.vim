let s:language_server_version = '1.20.8'
let s:language_server_sha = '37f12b83df389802b7d4e293b3e1a986aca289c0'
let s:root = expand('<sfile>:h:h:h')
let s:bin = v:null

if has('nvim')
  let s:ide = 'neovim'
else
  let s:ide = 'vim'
endif

if !exists('s:editor_version')
  if has('nvim')
    let s:ide_version = matchstr(execute('version'), 'NVIM v\zs[^[:space:]]\+')
  else
    let major = v:version / 100
    let minor = v:version % 100
    if exists('v:versionlong')
      let patch = printf('%04d', v:versionlong % 1000)
      let s:ide_version =  major . '.' . minor . '.' . patch
    else
      let s:ide_version =  major . '.' . minor
    endif
  endif
endif

let s:server_port = v:null
if gemini#util#IsUsingRemoteChat()
  let s:server_port = 42100
endif

let g:gemini_server_job = v:null

function! s:DetectGlibcVersion() abort
  if !has('unix') || has('mac')
    return v:null
  endif

  try
    try
      let ldd_output = system('ldd --version 2>/dev/null')
      if v:shell_error == 0
        let match = matchlist(ldd_output, 'ldd (GNU libc) \(\d\+\.\d\+\)')
        if !empty(match)
          call gemini#log#Info('Detected glibc version via ldd: ' . match[1])
          return match[1]
        endif
      endif
    catch
    endtry

    try
      let getconf_output = system('getconf GNU_LIBC_VERSION 2>/dev/null')
      if v:shell_error == 0
        let match = matchlist(getconf_output, 'glibc \(\d\+\.\d\+\)')
        if !empty(match)
          call gemini#log#Info('Detected glibc version via getconf: ' . match[1])
          return match[1]
        endif
      endif
    catch
    endtry

    try
      let libc_output = system('/lib/x86_64-linux-gnu/libc.so.6 2>/dev/null')
      if v:shell_error == 0
        let match = matchlist(libc_output, 'GNU C Library.*release version \(\d\+\.\d\+\)')
        if !empty(match)
          call gemini#log#Info('Detected glibc version via libc.so.6: ' . match[1])
          return match[1]
        endif
      endif
    catch
    endtry

    call gemini#log#Warn('Could not detect glibc version using any method')
    return v:null
  catch
    call gemini#log#Error('Error detecting glibc version: ' . v:exception)
    return v:null
  endtry
endfunction

function! s:CompareVersions(version1, version2) abort
  let parts1 = split(a:version1, '\.')
  let parts2 = split(a:version2, '\.')
  
  let major1 = str2nr(parts1[0])
  let minor1 = str2nr(parts1[1])
  let major2 = str2nr(parts2[0])
  let minor2 = str2nr(parts2[1])
  
  if major1 != major2
    return major1 < major2 ? -1 : 1
  endif
  
  if minor1 != minor2
    return minor1 < minor2 ? -1 : 1
  endif
  
  return 0
endfunction

function! s:IsGlibcVersionLessOrEqual(target_version) abort
  let current_version = s:DetectGlibcVersion()
  if current_version is# v:null
    return v:false
  endif
  
  return s:CompareVersions(current_version, a:target_version) <= 0
endfunction

function! s:OnExit(result, status, on_complete_cb) abort
  let did_close = has_key(a:result, 'closed')
  if did_close
    call remove(a:result, 'closed')
    call a:on_complete_cb(a:result.out, a:result.err, a:status)
  else
    " Wait until we receive OnClose, and call on_complete_cb then.
    let a:result.exit_status = a:status
  endif
endfunction

function! s:OnClose(result, on_complete_cb) abort
  let did_exit = has_key(a:result, 'exit_status')
  if did_exit
    call a:on_complete_cb(a:result.out, a:result.err, a:result.exit_status)
  else
    " Wait until we receive OnExit, and call on_complete_cb then.
    let a:result.closed = v:true
  endif
endfunction

function! s:NoopCallback(...) abort
endfunction

function! gemini#server#RequestMetadata() abort
  return {
        \ 'api_key': gemini#command#ApiKey(),
        \ 'ide_name':  s:ide,
        \ 'ide_version':  s:ide_version,
        \ 'extension_name': 'vim',
        \ 'extension_version':  s:language_server_version,
        \ }
endfunction

function! gemini#server#Request(type, data, ...) abort
  if s:server_port is# v:null
    throw 'Server port has not been properly initialized.'
  endif
  let uri = 'http://127.0.0.1:' . s:server_port .
      \ '/exa.language_server_pb.LanguageServerService/' . a:type
  let data = json_encode(a:data)
  let args = [
              \ 'curl', '-L', uri,
              \ '--header', 'Content-Type: application/json',
              \ '-d@-'
              \ ]
  let result = {'out': [], 'err': []}
  let ExitCallback = a:0 && !empty(a:1) ? a:1 : function('s:NoopCallback')
  if has('nvim')
    let jobid = jobstart(args, {
                \ 'on_stdout': { channel, data, t -> add(result.out, join(data, "\n")) },
                \ 'on_stderr': { channel, data, t -> add(result.err, join(data, "\n")) },
                \ 'on_exit': { job, status, t -> ExitCallback(result.out, result.err, status) },
                \ })
    call chansend(jobid, data)
    call chanclose(jobid, 'stdin')
    return jobid
  else
    let job = job_start(args, {
                \ 'in_mode': 'raw',
                \ 'out_mode': 'raw',
                \ 'out_cb': { channel, data -> add(result.out, data) },
                \ 'err_cb': { channel, data -> add(result.err, data) },
                \ 'exit_cb': { job, status -> s:OnExit(result, status, ExitCallback) },
                \ 'close_cb': { channel -> s:OnClose(result, ExitCallback) }
                \ })
    let channel = job_getchannel(job)
    call ch_sendraw(channel, data)
    call ch_close_in(channel)
    return job
  endif
endfunction

function! s:FindPort(dir, timer) abort
  let time = localtime()
  for name in readdir(a:dir)
    let path = a:dir . '/' . name
    if time - getftime(path) <= 5 && getftype(path) ==# 'file'
      call gemini#log#Info('Found port: ' . name)
      let s:server_port = name
      call s:RequestServerStatus()
      call timer_stop(a:timer)
      break
    endif
  endfor
endfunction

function! s:RequestServerStatus() abort
  call gemini#server#Request('GetStatus', {'metadata': gemini#server#RequestMetadata()}, function('s:HandleGetStatusResponse'))
endfunction

function! s:HandleGetStatusResponse(out, err, status) abort
  " Check if the request was successful
  if a:status == 0
    " Parse the JSON response
    let response = json_decode(join(a:out, "\n"))
    let status = get(response, 'status', {})
    " Check if there is a message in the response and echo it
    if has_key(status, 'message') && !empty(status.message)
      echom status.message
    endif
  else
    " Handle error if the status is not 0 or if there is stderr output
    call gemini#log#Error(join(a:err, "\n"))
  endif
endfunction

function! s:SendHeartbeat(timer) abort
  try
    call gemini#server#Request('Heartbeat', {'metadata': gemini#server#RequestMetadata()})
  catch
    call gemini#log#Exception()
  endtry
endfunction

function! gemini#server#Start(...) abort
  let user_defined_gemini_bin = get(g:, 'gemini_bin', '')

  if user_defined_gemini_bin != '' && filereadable(user_defined_gemini_bin)
    let s:bin = user_defined_gemini_bin
    call s:ActuallyStart()
    return
  endif
  let user_defined_os = get(g:, 'gemini_os', '')
  let user_defined_arch = get(g:, 'gemini_arch', '')

  if user_defined_os != '' && user_defined_arch != ''
    let os = user_defined_os
    let arch = user_defined_arch
  else
    silent let os = substitute(system('uname'), '\n', '', '')
    silent let arch = substitute(system('uname -m'), '\n', '', '')
  endif
  let is_arm = stridx(arch, 'arm') == 0 || stridx(arch, 'aarch64') == 0

  if empty(os)
    if has("linux")
      let os = "Linux"
    elseif has("mac")
      let os = "Darwin"
    endif
  endif

  if os ==# 'Linux' && is_arm
    let bin_suffix = 'linux_arm'
  elseif os ==# 'Linux'
    let bin_suffix = 'linux_x64'
  elseif os ==# 'Darwin' && is_arm
    let bin_suffix = 'macos_arm'
  elseif os ==# 'Darwin'
    let bin_suffix = 'macos_x64'
  else
    let bin_suffix = 'windows_x64.exe'
  endif

  let config = get(g:, 'gemini_server_config', {})
  if has_key(config, 'portal_url') && !empty(config.portal_url)
    let has_old_glibc = s:IsGlibcVersionLessOrEqual('2.27')
    if has_old_glibc
      call gemini#log#Info('Using legacy language server version 1.46.0 for enterprise customer with glibc <= 2.27')
      let s:language_server_version = '1.46.0'
      let s:language_server_sha = 'enterprise-' . s:language_server_version
    else
      let response = system('curl -sL ' . config.portal_url . '/api/version')
      if v:shell_error == '0'
        let s:language_server_version = response
        let s:language_server_sha = 'enterprise-' . s:language_server_version
      else
        call gemini#log#Error('Failed to fetch version from ' . config.portal_url)
        call gemini#log#Error(v:shell_error)
      endif
    endif
  endif

  let sha = get(gemini#command#LoadConfig(gemini#command#XdgConfigDir()), 'sha', s:language_server_sha)
  let bin_dir = gemini#command#HomeDir() . '/bin/' . sha
  let s:bin = bin_dir . '/language_server_' . bin_suffix
  call mkdir(bin_dir, 'p')

  if !filereadable(s:bin)
    call delete(s:bin)
    if sha ==# s:language_server_sha
      let config = get(g:, 'gemini_server_config', {})
      if has_key(config, 'portal_url') && !empty(config.portal_url)
        let base_url = config.portal_url
      else
        let base_url = 'https://github.com/Exafunction/gemini/releases/download'
      endif
      let base_url = substitute(base_url, '/\+$', '', '')
      let url = base_url . '/language-server-v' . s:language_server_version . '/language_server_' . bin_suffix . '.gz'
    else
      let url = 'https://storage.googleapis.com/exafunction-dist/gemini/' . sha . '/language_server_' . bin_suffix . '.gz'
    endif
    let args = ['curl', '-Lo', s:bin . '.gz', url]
    if has('nvim')
      let s:download_job = jobstart(args, {'on_exit': { job, status, t -> s:UnzipAndStart(status) }})
    else
      let s:download_job = job_start(args, {'exit_cb': { job, status -> s:UnzipAndStart(status) }})
    endif
  else
    call s:ActuallyStart()
  endif
endfunction

function! s:UnzipAndStart(status) abort
  if has('win32')
    " Save old settings.
    let old_shell = &shell
    let old_shellquote = &shellquote
    let old_shellpipe = &shellpipe
    let old_shellxquote = &shellxquote
    let old_shellcmdflag = &shellcmdflag
    let old_shellredir = &shellredir
    " Switch to powershell.
    let &shell = 'powershell'
    set shellquote=\"
    set shellpipe=\|
    set shellcmdflag=-NoLogo\ -NoProfile\ -ExecutionPolicy\ RemoteSigned\ -Command
    set shellredir=\|\ Out-File\ -Encoding\ UTF8
    call system('& { . ' . shellescape(s:root . '/powershell/gzip.ps1') . '; Expand-File ' . shellescape(s:bin . '.gz') . ' }')
    " Restore old settings.
    let &shell = old_shell
    let &shellquote = old_shellquote
    let &shellpipe = old_shellpipe
    let &shellxquote = old_shellxquote
    let &shellcmdflag = old_shellcmdflag
    let &shellredir = old_shellredir
  else
    if !executable('gzip')
      call gemini#log#Error('Failed to extract language server binary: missing `gzip`.')
      return ''
    endif
    call system('gzip -d ' . s:bin . '.gz')
    call system('chmod +x ' . s:bin)
  endif
  if !filereadable(s:bin)
    call gemini#log#Error('Failed to download language server binary.')
    return ''
  endif
  call s:ActuallyStart()
endfunction

function! s:ActuallyStart() abort
  let config = get(g:, 'gemini_server_config', {})
  let chat_ports = get(g:, 'gemini_port_config', {})
  let manager_dir = tempname() . '/gemini/manager'
  call mkdir(manager_dir, 'p')
  let args = [
        \ s:bin,
        \ '--api_server_url', get(config, 'api_url', 'https://server.gemini.com'),
        \ '--enable_local_search', '--enable_index_service', '--search_max_workspace_file_count', '5000',
        \ '--enable_chat_web_server', '--enable_chat_client'
        \ ]
  if has_key(config, 'api_url') && !empty(config.api_url)
    let args += ['--enterprise_mode']
    let args += ['--portal_url', get(config, 'portal_url', 'https://gemini.example.com')]
  endif
  if !gemini#util#IsUsingRemoteChat()
    let args += ['--manager_dir', manager_dir]
  endif
  " If either of these is set, only one vim window (with any number of buffers) will work with Gemini.
  " Opening other vim windows won't be able to use Gemini features.
  if has_key(chat_ports, 'web_server') && !empty(chat_ports.web_server)
    let args += ['--chat_web_server_port', chat_ports.web_server]
  endif
  if has_key(chat_ports, 'chat_client') && !empty(chat_ports.chat_client)
    let args += ['--chat_client_port', chat_ports.chat_client]
  endif

  call gemini#log#Info('Launching server with manager_dir ' . manager_dir)
  if has('nvim')
    let g:gemini_server__job = jobstart(args, {
                \ 'on_stderr': { channel, data, t -> gemini#log#Info('[SERVER] ' . join(data, "\n")) },
                \ })
  else
    let g:gemini_server_job = job_start(args, {
                \ 'out_mode': 'raw',
                \ 'err_cb': { channel, data -> gemini#log#Info('[SERVER] ' . data) },
                \ })
  endif
  if !gemini#util#IsUsingRemoteChat()
    call timer_start(500, function('s:FindPort', [manager_dir]), {'repeat': -1})
  endif

  call timer_start(5000, function('s:SendHeartbeat', []), {'repeat': -1})
endfunction
