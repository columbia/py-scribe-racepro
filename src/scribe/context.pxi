from libc.stdlib cimport *
from libc.errno cimport *
from linux cimport *
cimport scribe_api
cimport cpython
import os
import sys
import subprocess
import gc
import pickle
import traceback
import mmap
import signal
from collections import deque

cdef void on_backtrace(void *private_data, loff_t *log_offset, int num) with gil:
    # We can't use generators because of cython limitations
    log_offsets = list(log_offset[i] for i in range(num))
    try:
        (<Context>private_data).on_backtrace(log_offsets)
    except:
        traceback.print_exc()

cdef void on_diverge(void *private_data, scribe_api.scribe_event_diverge *event) with gil:
    buffer = cpython.PyBytes_FromStringAndSize(
                 <char *>event,
                 scribe_api.sizeof_event(<scribe_api.scribe_event *>event))
    try:
        (<Context>private_data).on_diverge(Event_from_bytes(buffer))
    except:
        traceback.print_exc()

cdef void on_bookmark(void *private_data, int id, int npr) with gil:
    try:
        (<Context>private_data).on_bookmark(id, npr)
    except:
        traceback.print_exc()


cdef char **list_to_pstr(strings):
    cdef char **array
    cdef int num

    num = len(strings)
    array = <char **>malloc(sizeof(char *) * (num + 1))
    if not array:
        raise MemoryError

    for i, str in zip(range(num), strings):
        array[i] = str
    array[num] = NULL

    return array


cdef object pstr_to_dict(char_p_const *array):
    dct = dict()
    cdef bytes s
    while array != NULL and array[0] != NULL:
        s = array[0]
        kv = unicode(s, 'utf8').split('=')
        dct[kv[0]] = kv[1]
        array = array+1
    return dct


cdef object pstr_to_list(char_p_const *array):
    lst = list()
    cdef bytes s
    while array != NULL and array[0] != NULL:
        s = array[0]
        lst.append(unicode(s, 'utf8'))
        array = array+1
    return lst


cdef void init_loader(void *private_data,
                      char_p_const *argv, char_p_const *envp) with gil:
    (<Context>private_data).init_loader(pstr_to_list(argv), pstr_to_dict(envp))


cdef scribe_api.scribe_operations scribe_ops= {
    'init_loader': init_loader,
    'on_backtrace': on_backtrace,
    'on_diverge': on_diverge,
    'on_bookmark': on_bookmark
}


class DivergeError(Exception):
    def __init__(self, err, event, logfile, backtrace_offsets,
                 backtrace_all_pids, backtrace_num_last_events,
                 additional_trace=None):
        self.err = err
        self.event = event
        self.logfile = logfile
        self.has_backtrace = backtrace_offsets is not None
        self.backtrace_offsets = backtrace_offsets
        self.backtrace_all_pids = backtrace_all_pids
        self.backtrace_num_last_events = backtrace_num_last_events
        self.additional_trace = additional_trace

    def _get_events(self, it):
        cdef int bt_index
        cdef int bt_length
        cdef __u64 info_offset
        cdef __u64 bt_offset

        events = dict()

        sorted_offsets = list(self.backtrace_offsets)
        sorted_offsets.sort()
        bt_index = 0
        bt_length = len(sorted_offsets)
        for info, event in it:
            while True:
                info_offset = info.offset
                bt_offset = sorted_offsets[bt_index]

                if info_offset < bt_offset:
                    break;

                if info_offset == bt_offset:
                    events[info.offset] = (info, event)

                bt_index = bt_index + 1
                if bt_index == bt_length:
                    return events

        # We are missing events, but it's better than nothing
        return events

    def _dump_backtrace(self):
        strs = []
        strs.append("Backtrace (%d events):" % len(self.backtrace_offsets))

        try:
            logfile_map = mmap.mmap(self.logfile.fileno(), 0,
                                    prot = mmap.PROT_READ)
        except:
            strs.append("  I can't mmap the logfile, you're not getting a backtrace :(")
            return strs

        it = Annotate(EventsFromBuffer(logfile_map), remove_annotations=False)
        try:
            events = self._get_events(it)
        except:
            strs.append("The log file is invalid...")

        pid = None
        if not self.backtrace_all_pids and self.event:
            pid = self.event.pid
        last_events = {}

        def append_event_str(info, event):
            strs.append("  [%02d] %s%s%s" % (info.pid,
                                             ("", "    ")[info.in_syscall],
                                             "  " * info.res_depth,
                                             event))
        for offset in self.backtrace_offsets:
            try:
                (info, event) = events[offset]

                if self.backtrace_num_last_events:
                    if not last_events.has_key(info.pid):
                        last_events[info.pid] = deque()
                    last_events[info.pid].append((info, event))
                    if len(last_events[info.pid]) > self.backtrace_num_last_events:
                        last_events[info.pid].popleft()

                if pid and pid != info.pid:
                    continue

                append_event_str(info, event)
            except:
                strs.append("unknown event offset = %d" % offset)

        if self.backtrace_num_last_events:
            strs.append("Last events of each known process:")
            for pid in sorted(last_events.keys()):
                for info, event in last_events[pid]:
                    append_event_str(info, event)

        return strs

    def __str__(self):
        strs = []
        strs.append("")
        if self.has_backtrace:
            strs.extend(self._dump_backtrace())
        if self.event:
            strs.append("Replay Diverged:")
            strs.append("  [%02d] diverged on %s" % (self.event.pid, self.event))
        else:
            strs.append("Replay Diverged, err = %d (%s)" %
                        (self.err, os.strerror(self.err)))
        if self.additional_trace:
            strs.append("Additional trace:")
            for line in self.additional_trace.split('\n'):
                if line:
                    strs.append("  %s" % line)
        return '\n'.join(strs)



cdef class Context:
    cdef scribe_api.scribe_context_t _ctx
    cdef object logfile
    cdef object log_offsets
    cdef object diverge_event
    cdef bint show_dmesg
    cdef int backtrace_len
    cdef bint backtrace_all_pids
    cdef int backtrace_num_last_events
    cdef object custom_init_loaders

    def __init__(self, logfile, show_dmesg=False,
                 backtrace_len=100, backtrace_all_pids=False,
                 backtrace_num_last_events=0):

        err = scribe_api.scribe_context_create(&self._ctx,
                                               &scribe_ops, <void *>self)
        if err:
            self._ctx = NULL
            raise OSError(errno, os.strerror(errno))

        self.logfile = logfile
        self.show_dmesg = show_dmesg

        self.backtrace_len = backtrace_len
        self.backtrace_all_pids = backtrace_all_pids
        self.backtrace_num_last_events = backtrace_num_last_events

        self.custom_init_loaders = list()

    def __del__(self):
        if self._ctx:
            scribe_api.scribe_context_destroy(self._ctx)
            self._ctx = NULL

    def record(self, args, env, cwd=None, chroot=None,
               flags=scribe_api.SCRIBE_DEFAULT):
        cdef char **_args = NULL
        cdef char **_env = NULL
        cdef char *_cwd = NULL
        cdef char *_chroot = NULL

        bargs = list(arg.encode() for arg in args)
        if env is not None:
            benv = list(('%s=%s' % (k, v)).encode() for k, v in env.items())

        try:
            _args = list_to_pstr(bargs)
            if env is not None:
                _env = list_to_pstr(benv)

            if cwd:
                cwd = cwd.encode()
                _cwd = cwd
            if chroot:
                chroot = chroot.encode()
                _chroot = chroot

            pid = scribe_api.scribe_record(self._ctx, flags,
                                           self.logfile.fileno(), _args, _env,
                                           _cwd, _chroot)
            if pid < 0:
                raise OSError(errno, os.strerror(errno))
            return pid
        finally:
            free(_args)
            free(_env)

    def replay(self):
        self.log_offsets = None
        self.diverge_event = None
        if self.show_dmesg:
            os.system('dmesg -c > /dev/null')
        pid = scribe_api.scribe_replay(self._ctx, 0, self.logfile.fileno(),
                                       self.backtrace_len)
        if pid < 0:
            raise OSError(errno, os.strerror(errno))
        return pid

    def wait(self):
        while True:
            err = scribe_api.scribe_wait(self._ctx)
            if err == 0:
                break
            _errno = errno
            if err == -2 and _errno == EINTR:
                cpython.PyErr_CheckSignals()
                continue
            if _errno == scribe_api.EDIVERGE or self.log_offsets:
                dmesg = None
                if self.show_dmesg:
                    ps = subprocess.Popen('dmesg', stdout=subprocess.PIPE)
                    (dmesg, _) = ps.communicate()
                    dmesg = dmesg.decode()
                raise DivergeError(err = _errno,
                                   event = self.diverge_event,
                                   logfile = self.logfile,
                                   backtrace_offsets = self.log_offsets,
                                   backtrace_all_pids = self.backtrace_all_pids,
                                   backtrace_num_last_events = self.backtrace_num_last_events,
                                   additional_trace = dmesg)
            raise OSError(_errno, os.strerror(_errno))

    def stop(self):
        err = scribe_api.scribe_stop(self._ctx)
        if err:
            raise OSError(errno, os.strerror(errno))

    def resume(self):
        err = scribe_api.scribe_resume(self._ctx)
        if err:
            raise OSError(errno, os.strerror(errno))

    def bookmark(self):
        err = scribe_api.scribe_bookmark(self._ctx)
        if err:
            raise OSError(errno, os.strerror(errno))

    def check_deadlock(self):
        err = scribe_api.scribe_check_deadlock(self._ctx)
        if err:
            raise OSError(errno, os.strerror(errno))

    def add_init_loader(self, func):
        self.custom_init_loaders.append(func)

    def init_loader(self, argv, envp):
        for func in self.custom_init_loaders:
            func(argv, envp)
        if len(self.custom_init_loaders):
            return

        bargv = list(arg.encode() for arg in argv)
        _argv = list_to_pstr(bargv)
        benvp = list(env.encode() for env in envp)
        _envp = list_to_pstr(benvp)
        scribe_api.scribe_default_init_loader(_argv, _envp)

    def on_backtrace(self, log_offsets):
        self.log_offsets = log_offsets

    def on_diverge(self, event):
        self.diverge_event = event

    def on_bookmark(self, id, npr):
        self.resume()



class Popen(subprocess.Popen):
    def __init__(self, Context context, args=None, bufsize=0, executable=None,
                 stdin=None, stdout=None, stderr=None,
                 preexec_fn=None, close_fds=True, shell=False,
                 cwd=None, chroot=None, env=None, universal_newlines=False,
                 record=False, replay=False,
                 flags=scribe_api.SCRIBE_DEFAULT,
                 startupinfo=None, creationflags=0):
        """ XXX close_fds=True by default
        """

        if not record ^ replay:
            raise ValueError('Please provide one of the two mode: record, or '
                             'replay')
        if record and not args:
            raise ValueError('Please provide some arguments')
        if replay:
            if args or env or cwd or chroot:
                raise ValueError('During replay args, env, cwd, chroot '
                                 'cannot be specified')

        self.context = context
        self.do_record = record
        self.flags = flags
        self.chroot = chroot

        context.add_init_loader(lambda argv, envp: self.init_loader(argv, envp))

        subprocess.Popen.__init__(self, args,
                bufsize=bufsize, executable=executable,
                 stdin=stdin, stdout=stdout, stderr=stderr,
                 preexec_fn=preexec_fn, close_fds=close_fds, shell=shell,
                 cwd=cwd, env=env, universal_newlines=universal_newlines,
                 startupinfo=startupinfo, creationflags=creationflags)

    def init_loader(self, args, env):
        (preexec_fn, close_fds, cwd, p2cread, p2cwrite,
         c2pread, c2pwrite, errread, errwrite,
         errpipe_read, errpipe_write) = self.child_args

        # Child
        try:
            # Close parent's pipe ends
            if p2cwrite is not None:
                os.close(p2cwrite)
            if c2pread is not None:
                os.close(c2pread)
            if errread is not None:
                os.close(errread)
            os.close(errpipe_read)

            # Dup fds for child
            if p2cread is not None:
                os.dup2(p2cread, 0)
            if c2pwrite is not None:
                os.dup2(c2pwrite, 1)
            if errwrite is not None:
                os.dup2(errwrite, 2)

            # Close pipe fds.  Make sure we don't close the
            # same fd more than once, or standard fds.
            if p2cread is not None and p2cread not in (0,):
                os.close(p2cread)
            if c2pwrite is not None and \
                                c2pwrite not in (p2cread, 1):
                os.close(c2pwrite)
            if (errwrite is not None and
                errwrite not in (p2cread, c2pwrite, 2)):
                os.close(errwrite)

            # Close all other fds, if asked for
            if close_fds:
                self._close_fds(but=errpipe_write)

            # We don't need to cwd because it's done by libscribe

            if preexec_fn:
                preexec_fn()

            signal.signal(signal.SIGPIPE, signal.SIG_DFL)

            if env is None:
                os.execvp(args[0], args)
            else:
                os.execvpe(args[0], args, env)

        except:
            exc_type, exc_value, tb = sys.exc_info()
            # Save the traceback and attach it to the exception
            # object
            exc_lines = traceback.format_exception(exc_type,
                                                   exc_value,
                                                   tb)
            exc_value.child_traceback = ''.join(exc_lines)
            os.write(errpipe_write, pickle.dumps(exc_value))

        # This exitcode won't be reported to applications, so
        # it really doesn't matter what we return.
        os._exit(255)


    def _execute_child(self, args, executable, preexec_fn, close_fds,
                       cwd, env, universal_newlines,
                       startupinfo, creationflags, shell,
                       p2cread, p2cwrite,
                       c2pread, c2pwrite,
                       errread, errwrite):
        """Execute program (POSIX version)"""

        if self.do_record:
            if isinstance(args, str):
                args = [args]
            else:
                args = list(args)

            if shell:
                args = ["/bin/sh", "-c"] + args

            if executable is None:
                executable = args[0]

        # For transferring possible exec failure from child to parent
        # The first char specifies the exception type: 0 means
        # OSError, 1 means some other error.
        errpipe_read, errpipe_write = os.pipe()

        self.child_args = (preexec_fn, close_fds, cwd, p2cread, p2cwrite,
                           c2pread, c2pwrite, errread, errwrite,
                           errpipe_read, errpipe_write)

        try:
            try:
                self._set_cloexec_flag(errpipe_write)

                gc_was_enabled = gc.isenabled()
                # Disable gc to avoid bug where gc -> file_dealloc ->
                # write to stderr -> hang. http://bugs.python.org/issue1336
                gc.disable()
                try:
                    if self.do_record:
                        self.pid = self.context.record(args, env, cwd,
                                                       self.chroot, self.flags)
                    else:
                        self.pid = self.context.replay()
                except:
                    if gc_was_enabled:
                        gc.enable()
                    raise
                self._child_created = True
                # Parent
                if gc_was_enabled:
                    gc.enable()
            finally:
                # be sure the FD is closed no matter what
                os.close(errpipe_write)

            if p2cread is not None and p2cwrite is not None:
                os.close(p2cread)
            if c2pwrite is not None and c2pread is not None:
                os.close(c2pwrite)
            if errwrite is not None and errread is not None:
                os.close(errwrite)

            # Wait for exec to fail or succeed; possibly raising an
            # exception (limited to 1 MB)
            data = subprocess._eintr_retry_call(os.read, errpipe_read, 1048576)
        finally:
            # be sure the FD is closed no matter what
            os.close(errpipe_read)
            del self.child_args

        if data:
            subprocess._eintr_retry_call(os.waitpid, self.pid, 0)
            child_exception = pickle.loads(data)
            for fd in (p2cwrite, c2pread, errread):
                if fd is not None:
                    os.close(fd)
            raise child_exception
