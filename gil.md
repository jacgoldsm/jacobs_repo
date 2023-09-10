# The Global Interpreter Lock (GIL) Does Not Make Python Threadsafe

On July 28, 2023 the Python Steering Committee [made the preliminary decision](https://discuss.python.org/t/a-steering-council-notice-about-pep-703-making-the-global-interpreter-lock-optional-in-cpython/30474)
to accept [Pep 703: Making the Global Interpreter Lock Optional in CPython](https://peps.python.org/pep-0703/). There is a lot of confusion about what the GIL really is and what removing it means.
This blog post is an attempt to clear up those misconceptions.

## What is the GIL

The Global Interpreter Lock, or GIL, is a [mutual exclusion lock](https://en.wikipedia.org/wiki/Lock_(computer_science)). A mutual exclusion lock (mutex) is a tool used to coordinate access to
shared objects in a multithreaded programming environment. In its simplest form, a mutex is a binary flag that only allows one thread to access an object at once. In order to read or write 
from the object, a thread must "acquire" the mutex. Since only one thread can acquire the mutex at once, only one thread can access the object at one time.

The GIL is a lock applied to a specific object, the [interpreter state](https://docs.python.org/3/c-api/init.html#c.PyInterpreterState). 
The interpreter state is a C struct that contains a reference to every Python object that is accessible from the current runtime state. Usually, there is only one runtime state per process,
however it is possible to create additional "subinterpreters" that are logically isolated from the main interpreter state. In general, the use of subinterpreters won't be relevant to this post,
so we'll use the case of a single main interpreter in examples.

A program must acquire the GIL for a given interpreter state in order to read from or write to it. This means that objects that are referenced by the interpreter--for example, builtin modules,
global variables, local variables, and extension modules--can only be accessed from one thread at a time. A program can release the GIL so long as it doesn't access the interpreter state.
For example, a program that spends a lot of time waiting for data to be sent over the internet or returned by the operating system can isolate the IO-receiving code from the Python-accessing code.
Then, it can request the data, spawn a new (logical) thread, and poll the request in the GIL-less thread at the same time as it conducts business requiring the interpreter state from the main thread.
When the subthread receives the data it was waiting for, it can make that data accessible process-wide and destroy itself. The data can then be processed by the main thread that holds the GIL.

## What the GIL is good for?
The GIL prevents the state of the Python interpreter from being corrupted by accesses from multiple threads. For example, the following code could crash Python without the GIL:
```python
```
Even with the GIL, the prior code is not threadsafe; however any bugs that arise from it will come in the form of results that the programmer does not want, it will not crash Python. 

Obviously, this is desirable, however the same effect can be achieved with per-object locking. With per-object locking, rather than one mutex for the entire interpreter state, each Python object
gets its own lock. This has the exact same benefits as the GIL--the interpreter state cannot be corrupted--but without the downsides of the GIL, as multiple threads can access their own variables
as long as they don't step on each other's toes and create a race condition. The prior code is *exactly as safe with the GIL and without the GIL*. 

That is the key takeaway--**the GIL *does not*
make unsafe code safe**. Code that is safe with the GIL is just as safe with per-object locking, and code that is not threadsafe with per object locking will be no more threadsafe with the GIL.
PEP 703 replaces the GIL with per-object locks, and thus has absolutely no effect on the thread-safety of any (pure Python) program.

## What is the downside of Removing the GIL?
If removing the GIL does not reduce the thread-safety of Python programs, what is the problem with just removing it? Why did this take so long to do?

In part, removing the GIL took so long because of backwards compatibility concerns. C extension modules will all have to be recompiled for a GIL-less world, and some will have to be
(modestly) rewritten to make use of new APIs introduced with the excission of the GIL. In some cases, C extension authors relied on the GIL to manage their own program's threadsafety
guarantees, and these programs will need to be modified to use their own locks.

This isn't the biggest challenge with excising the GIL, however. The biggest problem is reference counting.

## Reference Counting and the Garbage Collector
Python, like most modern languages, has automatic memory management. That means that the memory associated with an object is automatically freed by
Python when the object is no longer accessible without having to be explicitly freed by the programmer. 

The primary method of memory management in Python uses a scheme called [Reference counting](https://en.wikipedia.org/wiki/Reference_counting).
In Python, every variable (except [immortal objects](https://peps.python.org/pep-0683/)) has an integer
stored within its C structure. That integer, called the reference count, represents the number of references that the program holds to the object.
Follow along with the following code:

```python
x = "foo" # refcount = 1
y = x # refcount = 2
del x # refcount = 1
del y # refcount = 0; object is destroyed
```
Once the refcount of an object hits 0, the object is immediately destroyed and the memory owned by the object is freed.
This scheme, however, clearly breaks with multiple threads where the reference count is not being constantly syncronized between the threads:

```python
from threading import Thread

x = "foo"
t = Thread(target=lambda: print(x), args=[])
t.run()
del x
```
In that code, x is deleted while the code in `t` is still running, triggering the deletion of the object at the same time as `t` was attempting
to print it, potentially causing the interpreter to crash as `t` attempts to access a block of memory that's already been cleared. Note that
the GIL would prevent this from happening; `t` couldn't start printing `x` until the main thread released the GIL, at which point `x` is already
cleared, and so the `print` call in `t` would raise a `NameError` and not crash.

## Biased Reference Counting
It is possible to make reference counting threadsafe by simply synchronizing the reference count after every operation. However, the overhead of
this would be unacceptably high. The solution described in PEP 703 is an implementation of [Biased reference counting](https://dl.acm.org/doi/abs/10.1145/3243176.3243195). Sam Gross describes the idea:

> [Biased reference counting] is based on the observation that most objects are only accessed by a single thread, even in multi-threaded programs. Each
> object is associated with an owning thread (the thread that created it). Reference counting operations from the owning thread use non-atomic
> instructions to modify a “local” reference count. Other threads use atomic instructions to modify a “shared” reference count. This design avoids many
> atomic read-modify-write operations that are expensive on contemporary processors.

Biased reference counting adds two counters to each object: one for the thread that owns the object, and another for all the other threads. The counter
held by the owning thread is not threadsafe. However, when the owning thread's count reaches zero, the object is not automatically deallocated. Instead,
the owning thread merges its counter with the shared one. If the combined count is zero, the object is deallocated, otherwise all remaining reference
counting is done on the shared reference counter in a threadsafe (and thus slower) manner. 

That can't be the only way for an object to be deallocated, since other threads are capable of removing references to the object that were added by
the owning thread. To account for this, if the shared reference counter drops below zero (meaning non-owning threads have destroyed more references than
they have created), then whichever non-owning thread is responsible for making the shared reference count go negative places the object in a queue 
belonging to the owning thread. For each object in its queue, the owning thread then merges its own reference count and the shared reference count.
Just as in the previous case, if the merged reference count is zero, the object is deallocated, otherwise the program falls back to the slow,
fully synchronizing reference counting scheme.

## Other Changes
