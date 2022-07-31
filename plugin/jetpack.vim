"=================================== Jetpack ==================================
"Copyright (c) 2022 TANIGUCHI Masaya
"
"Permission is hereby granted, free of charge, to any person obtaining a copy
"of this software and associated documentation files (the "Software"), to deal
"in the Software without restriction, including without limitation the rights
"to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
"copies of the Software, and to permit persons to whom the Software is
"furnished to do so, subject to the following conditions:
"
"The above copyright notice and this permission notice shall be included in all
"copies or substantial portions of the Software.
"
"THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
"IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
"FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
"AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
"LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
"OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
"SOFTWARE.
"==============================================================================

if exists('g:loaded_jetpack')
  finish
endif
let g:loaded_jetpack = 1

let g:jetpack_njobs = get(g:, 'jetpack_njobs', 8)

let g:jetpack_ignore_patterns =
  \ get(g:, 'jetpack_ignore_patterns', [
  \   '[\/]doc[\/]tags*',
  \   '[\/]test[\/]*',
  \   '[\/][.ABCDEFGHIJKLMNOPQRSTUVWXYZ]*'
  \ ])

let g:jetpack_download_method =
  \ get(g:, 'jetpack_download_method', 'git')
  " curl: Use CURL to download
  " wget: Use Wget to download

let g:jetpack_copy_method =
  \ get(g:, 'jetpack_copy_method', 'system')
  " sytem    : cp/ xcopy
  " copy     : readfile and writefile
  " symlink  : fs_symlink (nvim only)
  " hardlink : fs_link (nvim only)

let s:packages = get(s:, 'packages', {})
let s:optdir = ''
let s:srcdir = ''

let s:status = {
\   'pending': 'pending',
\   'skipped': 'skipped',
\   'installed': 'installed',
\   'installing': 'installing',
\   'updated': 'updated',
\   'updating': 'updating',
\   'switched': 'switched',
\   'merged': 'merged',
\   'copied': 'copied'
\ }

def! s:list_files(path: string): list<string>
  return filter(glob(path .. '/**/*', false, 1), (_, val) => (!isdirectory(val)))
enddef

def! s:check_ignorable(filename: string): bool
  return filter(copy(g:jetpack_ignore_patterns), (_, val) => (filename =~# glob2regpat(val))) != []
enddef

def! s:make_progressbar(n: float): string
  return '[' .. join(map(range(0, 100, 3), (_, v) => (v < n ? '=' : ' ')), '') .. ']'
enddef

def! s:jobstatus(job: job): string
  # neovim does't support vim9 script but I left this statement
  # if has('nvim')
  #   return jobwait([a:job], 0)[0] == -1 ? 'run' : 'dead'
  # endif
  return job_status(job)
enddef

def! s:jobcount(jobs: list<job>): number
  return len(filter(copy(jobs), (_, val) => (s:jobstatus(val) ==# 'run')))
enddef

def! s:jobwait(jobs: list<job>, njobs: number)
  var running = s:jobcount(jobs)
  while running > njobs
    running = s:jobcount(jobs)
  endwhile
enddef

" Original: https://github.com/lambdalisue/vital-Whisky/blob/90c71/autoload/vital/__vital__/System/Job/Vim.vim#L46
"  License: https://github.com/lambdalisue/vital-Whisky/blob/90c71/LICENSE
" in Vim9 script, Vim cannot create funcref for functions starting with capital
def! s:Nvim_exit_cb(buf: list<string>, Cb: func, job: job, ...args: list<any>)
  var ch = job_getchannel(job)
  while ch_status(ch) ==# 'open' | sleep 1ms | endwhile
  while ch_status(ch) ==# 'buffered' | sleep 1ms | endwhile
  call Cb(join(buf, "\n"))
enddef

def! s:jobstart(cmd: list<string>, Cb: func): job
  # if has('nvim')
  #   let buf = []
  #   return jobstart(a:cmd, {
  #   \   'on_stdout': { _, data -> extend(buf, data) },
  #   \   'on_stderr': { _, data -> extend(buf, data) },
  #   \   'on_exit': { -> a:cb(join(buf, "\n")) }
  #   \ })
  # else
  var buf: list<string> = []
  return job_start(cmd, {
  \   'out_mode': 'raw',
  \   'out_cb': (_, data) => (extend(buf, split(data, "\n"))),
  \   'err_mode': 'raw',
  \   'err_cb': (_, data) => (extend(buf, split(data, "\n"))),
  \   'exit_cb': function('s:Nvim_exit_cb', [buf, Cb])
  \ })
  #endif
enddef

def! s:copy_dir(from: string, to: string)
  mkdir(to, 'p')
  if g:jetpack_copy_method !=# 'system'
    for src in s:list_files(from)
      var dest = substitute(src, '\V' .. escape(from, '\'), escape(to, '\'), '')
      mkdir(fnamemodify(dest, ':p:h'), 'p')
      if g:jetpack_copy_method ==# 'copy'
        writefile(readfile(src, 'b'), dest, 'b')
      # elseif g:jetpack_copy_method ==# 'hardlink'
      #   call v:lua.vim.loop.fs_link(src, dest)
      # elseif g:jetpack_copy_method ==# 'symlink'
      #   call v:lua.vim.loop.fs_symlink(src, dest)
      endif
    endfor
  elseif has('unix')
    system(printf('cp -R %s/. %s', from, to))
  elseif has('win32')
    system(printf('xcopy %s %s /E /Y', expand(from), expand(to)))
  endif
enddef

def! s:initialize_buffer()
  execute 'silent! bdelete! ' .. bufnr('JetpackStatus')
  :40vnew +setlocal\ buftype=nofile\ nobuflisted\ nonumber\ norelativenumber\ signcolumn=no\ noswapfile\ nowrap JetpackStatus
  syntax clear
  syntax match jetpackProgress /^[a-z]*ing/
  syntax match jetpackComplete /^[a-z]*ed/
  syntax keyword jetpackSkipped ^skipped
  highlight def link jetpackProgress DiffChange
  highlight def link jetpackComplete DiffAdd
  highlight def link jetpackSkipped DiffDelete
  redraw
enddef

def! s:show_progress(title: string)
  var buf = bufnr('JetpackStatus')
  deletebufline(buf, 1, '$')
  var processed = len(filter(copy(s:packages), (_, val) => (val.status[-1] =~# 'ed')))
  setbufline(buf, 1, printf('%s (%d / %d)', title, processed, len(s:packages)))
  appendbufline(buf, '$', s:make_progressbar((0.0 + processed) / len(s:packages) * 100.0))
  for [pkg_name, pkg] in items(s:packages)
    appendbufline(buf, '$', printf('%s %s', pkg.status[-1], pkg_name))
  endfor
  redraw
enddef

def! s:show_result()
  var buf = bufnr('JetpackStatus')
  deletebufline(buf, 1, '$')
  setbufline(buf, 1, 'Result')
  appendbufline(buf, '$', s:make_progressbar(100.0))
  for [pkg_name, pkg] in items(s:packages)
    if index(pkg.status, s:status.installed) >= 0
      appendbufline(buf, '$', printf('installed %s', pkg_name))
    elseif index(pkg.status, s:status.updated) >= 0
      appendbufline(buf, '$', printf('updated %s', pkg_name))
    else
      appendbufline(buf, '$', printf('skipped %s', pkg_name))
    endif
    var output = substitute(pkg.output, '[\x0]', '', 'g')
    output = substitute(output, '^From.\{-}\zs\(\r\n\|\r\|\n\)\s*', '/compare/', '')
    appendbufline(buf, '$', output)
  endfor
  redraw
enddef

def! s:clean_plugins()
  if g:jetpack_download_method !=# 'git'
    return
  endif
  for [pkg_name, pkg] in items(s:packages)
    if isdirectory(pkg.path)
      var branch = trim(system(printf('git -C %s rev-parse --abbrev-ref %s', pkg.path, pkg.commit)))
      if v:shell_error
        delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.branch) && pkg.branch !=# branch
        delete(pkg.path, 'rf')
        continue
      endif
      if !empty(pkg.tag) && pkg.tag !=# branch
        delete(pkg.path, 'rf')
        continue
      endif
    endif
  endfor
enddef

" if !(has('unix') || has('win32')) s:make_download_cmd returns nil
def! s:make_download_cmd(pkg: dict<any>): list<string>
  if g:jetpack_download_method ==# 'git'
    if isdirectory(pkg.path)
      return ['git', '-C', pkg.path, 'pull', '--rebase']
    else
      var cmd = ['git', 'clone']
      if pkg.commit ==# 'HEAD'
        extend(cmd, ['--depth', '1', '--recursive'])
      endif
      if !empty(pkg.branch)
        extend(cmd, ['-b', pkg.branch])
      endif
      if !empty(pkg.tag)
        extend(cmd, ['-b', pkg.tag])
      endif
      extend(cmd, [pkg.url, pkg.path])
      return cmd
    endif
  else
    var label = ""
    if !empty(pkg.tag)
      label = pkg.tag
    elseif !empty(pkg.branch)
      label = pkg.branch
    else
      label = pkg.commit
    endif
    var download_cmd = ""
    if g:jetpack_download_method ==# 'curl'
      download_cmd = 'curl -fsSL ' ..  pkg.url .. '/archive/' .. label .. '.tar.gz'
    elseif g:jetpack_download_method ==# 'wget'
      download_cmd = 'wget -O - ' ..  pkg.url .. '/archive/' .. label .. '.tar.gz'
    else
      throw 'g:jetpack_download_method: ' .. g:jetpack_download_method .. ' is not a valid value'
    endif
    var extract_cmd = 'tar -zxf - -C ' .. pkg.path .. ' --strip-components 1'
    call delete(pkg.path, 'rf')
    if has('unix')
      return ['sh', '-c', download_cmd .. ' | ' .. extract_cmd]
    elseif has('win32')
      return ['cmd.exe', '/c' .. download_cmd .. ' | ' .. extract_cmd]
    else
      # work around
      # Vim9 script can't define function which returns any or void
      return []
    endif
  endif
enddef

def! s:download_plugins()
  var jobs: list<job> = []
  for [pkg_name, pkg] in items(s:packages)
    add(pkg.status, s:status.pending)
  endfor
  for [pkg_name, pkg] in items(s:packages)
    s:show_progress('Install Plugins')
    var status_ = ''
    if isdirectory(pkg.path)
      if pkg.frozen
        add(pkg.status, s:status.skipped)
        continue
      endif
      add(pkg.status, s:status.updating)
      status_ = s:status.updated
    else
      add(pkg.status, s:status.installing)
      status_ = s:status.installed
    endif
    var cmd = s:make_download_cmd(pkg)
    mkdir(pkg.path, 'p')
    var job = s:jobstart(cmd, function((a_status, a_pkg, a_output) => {
      a_pkg.output = a_output
      add(pkg.status, a_status)
    }, [status, pkg]))
    add(jobs, job)
    s:jobwait(jobs, g:jetpack_njobs)
  endfor
  s:jobwait(jobs, 0)
enddef

def! s:switch_plugins()
  if g:jetpack_download_method !=# 'git'
    return
  endif
  for [pkg_name, pkg] in items(s:packages)
    add(pkg.status, s:status.pending)
  endfor
  for [pkg_name, pkg] in items(s:packages)
    s:show_progress('Switch Plugins')
    if !isdirectory(pkg.path)
      add(pkg.status, s:status.skipped)
      continue
    else
      add(pkg.status, s:status.switched)
    endif
    system(printf('git -C %s checkout %s', pkg.path, pkg.commit))
  endfor
enddef

def! s:merge_plugins()
  for [pkg_name, pkg] in items(s:packages)
    add(pkg.status, s:status.pending)
  endfor

  # If opt/do/dir option is enabled,
  # it should be placed isolated directory.
  var bundle = {}
  var unbundle = {}
  for [pkg_name, pkg] in items(s:packages)
    if pkg.opt || !empty(pkg.do) || !empty(pkg.dir)
      unbundle[pkg_name] = pkg
    else
      bundle[pkg_name] = pkg
    endif
  endfor

  # Delete old directories
  for dir in glob(s:optdir .. '/*', false, 1)
    var pkg_name = fnamemodify(dir, ':t')
    if !has_key(s:packages, pkg_name)
     \ || s:packages[pkg_name].output !~# 'Already up to date.'
      delete(dir, 'rf')
    endif
  endfor

  # Merge plugins if possible.
  var merged_files = []
  for [pkg_name, pkg] in items(bundle)
    s:show_progress('Merge Plugins')
    srcdir = pkg.path .. '/' .. pkg.rtp
    var files = map(s:list_files(srcdir), (_, file) => (file->slice(len(srcdir))))
    files = filter(files, (_, file) => (!s:check_ignorable(file)))
    var conflicted = false
    for file in files
      for merged_file in merged_files
        conflicted =
          \ file =~# '\V' .. escape(merged_file, '\') ||
          \ merged_file =~# '\V' .. escape(file, '\')
        if conflicted
          break
        endif
      endfor
      if conflicted
        break
      endif
    endfor
    if conflicted
      unbundle[pkg_name] = pkg
    else
      extend(merged_files, files)
      s:copy_dir(srcdir, s:optdir .. '/_')
      add(pkg.status, s:status.merged)
    endif
  endfor

  # Copy plugins.
  for [pkg_name, pkg] in items(unbundle)
    s:show_progress('Copy Plugins')
    if !empty(pkg.dir)
      add(pkg.status, s:status.skipped)
    else
      srcdir  = pkg.path .. '/' .. pkg.rtp
      var destdir = s:optdir .. '/' .. pkg_name
      s:copy_dir(srcdir, destdir)
      add(pkg.status, s:status.copied)
    endif
  endfor
enddef

def! s:postupdate_plugins()
  silent! packadd _
  for [pkg_name, pkg] in items(s:packages)
    if empty(pkg.do) || pkg.output =~# 'Already up to date.'
      continue
    endif
    var pwd = getcwd()
    if pkg.dir !=# ''
      chdir(pkg.path)
    else
      execute 'silent! packadd ' .. pkg_name
      chdir(s:optdir .. '/' .. pkg_name)
    endif
    if type(pkg.do) == v:t_func
      pkg.do()
    endif
    if type(pkg.do) != v:t_string
      continue
    endif
    if pkg.do =~# '^:'
      execute pkg.do
    else
      system(pkg.do)
    endif
    chdir(pwd)
  endfor
  for dir in glob(s:optdir .. '/*/doc', false, 1)
    execute 'silent! helptags ' .. dir
  endfor
enddef

function! jetpack#sync()
  call s:initialize_buffer()
  call s:clean_plugins()
  call s:download_plugins()
  call s:switch_plugins()
  call s:merge_plugins()
  call s:show_result()
  call s:postupdate_plugins()
endfunction

" TODO
function! jetpack#add(plugin, ...) abort
  let opts = a:0 > 0 ? a:1 : {}
  let url = (a:plugin !~# ':' ? 'https://github.com/' : '') . a:plugin
  let on = has_key(opts, 'on') ? (type(opts.on) ==# v:t_list ? opts.on : [opts.on]) : []
  let on = extend(on, has_key(opts, 'for') ? (type(opts.for) ==# v:t_list ? opts.for : [opts.for]) : [])
  let on = extend(on, has_key(opts, 'ft') ? (type(opts.ft) ==# v:t_list ? opts.ft : [opts.ft]) : [])
  let on = extend(on, has_key(opts, 'cmd') ? (type(opts.cmd) ==# v:t_list ? opts.cmd : [opts.cmd]) : [])
  let on = extend(on, has_key(opts, 'map') ? (type(opts.map) ==# v:t_list ? opts.map : [opts.map]) : [])
  let on = extend(on, has_key(opts, 'event') ? (type(opts.event) ==# v:t_list ? opts.event : [opts.event]) : [])
  let pkg  = {
  \   'url': url,
  \   'branch': get(opts, 'branch', ''),
  \   'tag': get(opts, 'tag', ''),
  \   'commit': get(opts, 'commit', 'HEAD'),
  \   'rtp': get(opts, 'rtp', ''),
  \   'do': get(opts, 'do', get(opts, 'run', '')),
  \   'frozen': get(opts, 'frozen', v:false),
  \   'dir': get(opts, 'dir', ''),
  \   'on': on,
  \   'opt': !empty(on) || get(opts, 'opt'),
  \   'path': get(opts, 'dir', s:srcdir . '/' .  substitute(url, 'https\?://', '', '')),
  \   'status': [s:status.pending],
  \   'output': '',
  \ }
  let s:packages[get(opts, 'as', fnamemodify(a:plugin, ':t'))] = pkg
endfunction

def! jetpack#begin(...a_home: list<string>)
  s:packages = {}
  if a_home->len() != 0
    s:home = expand(a_home[0])
    execute 'set packpath^=' .. s:home
    execute 'set runtimepath^=' .. s:home
  elseif has('nvim')
    s:home = stdpath('data') .. '/' .. 'site'
  elseif has('win32')
    s:home = expand('~/vimfiles')
  else
    s:home = expand('~/.vim')
  endif
  s:optdir = s:home .. '/pack/jetpack/opt'
  s:srcdir = s:home .. '/pack/jetpack/src'
  command! -nargs=+ -bar Jetpack call jetpack#add(<args>)
enddef

" Original: https://github.com/junegunn/vim-plug/blob/e3001/plug.vim#L683-L693
"  License: MIT, https://raw.githubusercontent.com/junegunn/vim-plug/e3001/LICENSE
function! s:load_map(map, name, with_prefix, prefix)
  execute 'packadd ' . a:name
  let extra = ''
  let code = getchar(0)
  while (code != 0 && code != 27)
    let extra .= nr2char(code)
    let code = getchar(0)
  endwhile
  if a:with_prefix
    let prefix = v:count ? v:count : ''
    let prefix .= '"'.v:register.a:prefix
    if mode(1) ==# 'no'
      if v:operator ==# 'c'
        let prefix = "\<Esc>" . prefix
      endif
      let prefix .= v:operator
    endif
    call feedkeys(prefix, 'n')
  endif
  call feedkeys(substitute(a:map, '^<Plug>', "\<Plug>", 'i') . extra)
endfunction

def! s:load_cmd(a_cmd: string, a_name: string, ...a_args: list<string>)
  execute printf('delcommand %s', a_cmd)
  execute printf('silent! packadd %s', a_name)
  var args = a_args->len() > 0 ? join(a_args, ' ') : ''
  try
    execute printf('%s %s', a_cmd, args)
  catch /.*/
    echohl ErrorMsg
    echomsg v:exception
    echohl None
  endtry
enddef

def! jetpack#end()
  delcommand Jetpack
  command! -bar JetpackSync call jetpack#sync()
  syntax off
  filetype plugin indent off
  augroup Jetpack
    autocmd!
  augroup END
  for [pkg_name, pkg] in items(s:packages)
    if !empty(pkg.dir)
      &runtimepath ..= printf(',%s/%s', pkg.dir, pkg.rtp)
      continue
    endif
    if !pkg.opt
      execute 'silent! packadd! ' .. pkg_name
      continue
    endif
    for it in pkg.on
      if it =~? '^<Plug>'
        execute printf('inoremap <silent> %s <C-\><C-O>:<C-U>call <SID>load_map(%s, %s, 0, "")<CR>', it, string(it), string(pkg_name))
        execute printf('nnoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "")<CR>',           it, string(it), string(pkg_name))
        execute printf('vnoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "gv")<CR>',         it, string(it), string(pkg_name))
        execute printf('onoremap <silent> %s :<C-U>call <SID>load_map(%s, %s, 1, "")<CR>',           it, string(it), string(pkg_name))
      elseif exists('##' .. substitute(it, ' .*', '', ''))
        var it_ = it
        it_ ..= (it_ =~? ' ' ? '' : ' *')
        execute printf('autocmd Jetpack %s ++once ++nested silent! packadd %s', it, pkg_name)
      elseif substitute(it, '^:', '', '') =~# '^[A-Z]'
        var cmd = substitute(it, '^:', '', '')
        execute printf('command! -range -nargs=* %s :call <SID>load_cmd(%s, %s, <f-args>)', cmd, string(cmd), string(pkg_name))
      else
        execute printf('autocmd Jetpack FileType %s ++once ++nested silent! packadd %s', it, pkg_name)
      endif
    endfor
    var event = substitute(pkg_name, '\W\+', '_', 'g')
    event = substitute(event, '\(^\|_\)\(.\)', '\u\2', 'g')
    execute printf('autocmd Jetpack SourcePre **/pack/jetpack/opt/%s/* ++once ++nested doautocmd User Jetpack%sPre', pkg_name, event)
    execute printf('autocmd Jetpack SourcePost **/pack/jetpack/opt/%s/* ++once ++nested doautocmd User Jetpack%sPost', pkg_name, event)
    execute printf('autocmd Jetpack User Jetpack%sPre :', event)
    execute printf('autocmd Jetpack User Jetpack%sPost :', event)
  endfor
  silent! packadd! _
  syntax enable
  filetype plugin indent on
enddef

def! jetpack#tap(name: string): bool
  return has_key(s:packages, name) && isdirectory(jetpack#get(name).path) ? true : false
enddef

def! jetpack#names(): list<string>
  return keys(s:packages)
enddef

def! jetpack#get(name: string): dict<any>
  return get(s:packages, name, {})
enddef

" if !has('nvim') | finish | endif
" lua<<========================================
" local M = {}
" 
" for _, name in pairs({'begin', 'end', 'add', 'names', 'get', 'tap', 'sync'}) do
"   M[name] = function(...) return vim.fn['jetpack#' .. name](...) end
" end
" 
" local function use(plugin)
"   if (type(plugin) == 'string') then
"     vim.fn['jetpack#add'](plugin)
"   else
"     local name = plugin[1]
"     plugin[1] = nil
"     if vim.fn.type(plugin) == vim.v.t_list then
"       vim.fn['jetpack#add'](name)
"     else
"       vim.fn['jetpack#add'](name, plugin)
"     end
"   end
" end
" 
" M.startup = function(config)
"   vim.fn['jetpack#begin']()
"   config(use)
"   vim.fn['jetpack#end']()
" end
" 
" M.setup = function(config)
"   vim.fn['jetpack#begin']()
"   for _, plugin in pairs(config) do
"     use(plugin)
"   end
"   vim.fn['jetpack#end']()
" end
" 
" package.preload['jetpack'] = function()
"   return M
" end
" ========================================
