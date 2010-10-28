from libc.stdlib cimport *
from libc.errno cimport *
from libc.string cimport *
from scribe_api cimport *
cimport cpython
import os

def Event_from_bytes(bytes buffer):
    cls, _, _ = Event_get_type_info(buffer[0])
    return cls(buffer)

def Event_get_type_info(type):
    return Event.class_of[type], \
            sizeof_event_from_type(type), \
            is_sized_type(type)

def Event_register(event_class, type):
    Event.class_of[type] = event_class
    return type

cpdef inline size_t Event_size_from_type(int type) except -1:
    return sizeof_event_from_type(type)

cdef class Event:
    class_of = dict()

    get_type_info = staticmethod(Event_get_type_info)
    register = staticmethod(Event_register)
    size_from_type = staticmethod(Event_size_from_type)
    from_bytes = staticmethod(Event_from_bytes)

    # We need to keep the event reference because event_struct won't
    cdef bytes event
    cdef scribe_event *event_struct

    def __init__(self, bytes event=None, int extra_size=0):
        cdef scribe_event h
        cdef int type = self.type
        # We prefer to use the cdef version for performance reasons.
        cdef size_t event_size = Event_size_from_type(type) + extra_size
        if event is None:
            h = {'type': type}
            header = cpython.PyBytes_FromStringAndSize(<char *>&h,
                                                       sizeof(scribe_event))
            self.event = header + bytes(event_size - len(header))
        else:
            assert event_size == len(event)
            self.event = event

        # XXX We cannot modify the struct as we are using
        # underlying bytes, and not a bytearray.
        self.event_struct = <scribe_event *>cpython.PyBytes_AsString(self.event)
        assert self.event_struct.type == type

    def __len__(self):
        return len(self.event)

    def __str__(self):
        cdef char buffer[4096]
        return scribe_get_event_str(buffer, sizeof(buffer),
                                    self.event_struct).decode()

    def encode(self):
        return self.event

cdef class EventSized(Event):
    pass

cdef class EventDiverge(Event):

    property pid:
        def __get__(self):
            return (<scribe_event_pid *>self.event_struct).pid

cdef class EventInit(EventSized):
    type = Event.register(EventInit, SCRIBE_EVENT_INIT)

cdef class EventPid(Event):
    type = Event.register(EventPid, SCRIBE_EVENT_PID)

    property pid:
        def __get__(self):
            return (<scribe_event_pid *>self.event_struct).pid

cdef class EventData(EventSized):
    type = Event.register(EventData, SCRIBE_EVENT_DATA)

    property user_ptr:
        def __get__(self):
            return (<scribe_event_data *>self.event_struct).user_ptr

    property data_type:
        def __get__(self):
            return (<scribe_event_data *>self.event_struct).data_type

    property data:
        def __get__(self):
            return cpython.PyBytes_FromStringAndSize(
                    <char *>(<scribe_event_data *>self.event_struct).data,
                    (<scribe_event_data *>self.event_struct).h.size)

cdef class EventSyscall(Event):
    type = Event.register(EventSyscall, SCRIBE_EVENT_SYSCALL)

    property ret:
        def __get__(self):
            return (<scribe_event_syscall *>self.event_struct).ret

    property nr:
        def __get__(self):
            return (<scribe_event_syscall *>self.event_struct).nr

cdef class EventSyscallEnd(Event):
    type = Event.register(EventSyscallEnd, SCRIBE_EVENT_SYSCALL_END)

cdef class EventQueueEof(Event):
    type = Event.register(EventQueueEof, SCRIBE_EVENT_QUEUE_EOF)

cdef class EventDivergeEventType(EventDiverge):
    type = Event.register(EventDivergeEventType,
                          SCRIBE_EVENT_DIVERGE_EVENT_TYPE)

    property event_type:
        def __get__(self):
            return (<scribe_event_diverge_event_type *>self.event_struct).type

cdef class EventDivergeEventSize(EventDiverge):
    type = Event.register(EventDivergeEventSize,
                          SCRIBE_EVENT_DIVERGE_EVENT_SIZE)

    property size:
        def __get__(self):
            return (<scribe_event_diverge_event_size *>self.event_struct).size

cdef class EventDivergeDataType(EventDiverge):
    type = Event.register(EventDivergeDataType,
                          SCRIBE_EVENT_DIVERGE_DATA_TYPE)

    property data_type:
        def __get__(self):
            return (<scribe_event_diverge_data_type *>self.event_struct).type

cdef class EventDivergeDataPtr(EventDiverge):
    type = Event.register(EventDivergeDataPtr,
                          SCRIBE_EVENT_DIVERGE_DATA_PTR)

    property user_ptr:
        def __get__(self):
            return (<scribe_event_diverge_data_ptr *>self.event_struct).user_ptr

cdef class EventDivergeDataContent(EventDiverge):
    type = Event.register(EventDivergeDataContent,
                          SCRIBE_EVENT_DIVERGE_DATA_CONTENT)

    property offset:
        def __get__(self):
            return (<scribe_event_diverge_data_content *>
                    self.event_struct).offset

    property data:
        def __get__(self):
            return cpython.PyBytes_FromStringAndSize(
                    <char *>(<scribe_event_diverge_data_content *>
                        self.event_struct).data,
                    (<scribe_event_diverge_data_content *>
                        self.event_struct).size)