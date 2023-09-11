# The Global Interpreter Lock (GIL) Does Not Make Python Threadsafe

On July 28, 2023 the Python Steering Committee [made the preliminary decision](https://discuss.python.org/t/a-steering-council-notice-about-pep-703-making-the-global-interpreter-lock-optional-in-cpython/30474)
to accept [Pep 703: Making the Global Interpreter Lock Optional in CPython](https://peps.python.org/pep-0703/). There is a lot of confusion about what the GIL really is and what removing it means.
This blog post is an attempt to clear up those misconceptions.

## What is CPython?

Python is a programming language with syntax and semantics described [here](https://docs.python.org/3/). Although the Python specification lays out the expected behavior of Python, it does not specify how that behavior should be implemented. CPython is an implementation of Python written in C and Python itself by Guido van Rossum. It is the original implementation of Python and it is considered its "reference implementation", meaning that implementers of Python should follow CPython's behavior where the documentation is unclear or ambiguous. It is also by far the most commonly used implementation of Python. Everything in this blog post applies to CPython specifically, not Python in general.

## What is the GIL?

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
The GIL prevents the state of the Python interpreter from being corrupted by accesses from multiple threads. For example, the following code could crash Python without the GIL, if thread `t` starts to append "foo" as the main thread is appending "bar", causing the interpreter to have an inconsistent
view of the size of the list:

```python
from threading import Thread

def f():
    do_stuff()
    x.append("foo")
    
x = []
t = Thread(target = f)
t.start()
x.append("bar")
```
Even with the GIL, the prior code is not threadsafe; however any bugs that arise from it will come in the form of results that the programmer does not want (in this case, an undesirable order of "foo" and "bar" in the list), it will not crash Python. 

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
This scheme, however, clearly breaks with multiple threads. Reference counting is not atomic; it consists of several machine instructions that are written with the internal assumption that they can execute in sequence without any other thread changing anything in the meantime. The following code potentially violates that assumption:


```python
from threading import Thread

x = "foo"
def f():
    do_stuff() # we don't know how long this will take
    global y
    y = x

t = Thread(target=f, args=[])
t.start()
del x
```
In this code, `del x` decrements the reference count of `x`, and `y = x` increments it. If reference counting is not atomic, we could have a situation
where thread `t` and the main thread attempt to modify the reference count at the same time, potentially causing a crash or incorrect data being written
to the reference count. Note that the GIL would prevent this from happening; if `x` were in the process of being deleted then any modifications to the interpreter state, like assigning `y` to `x`, would have to wait.

## Biased Reference Counting
It is possible to make reference counting threadsafe by simply making reference counting atomic. However, the overhead of
this would be unacceptably high. The solution described in PEP 703 is an implementation of [Biased reference counting](https://dl.acm.org/doi/abs/10.1145/3243176.3243195). Sam Gross describes the idea:

> [Biased reference counting] is based on the observation that most objects are only accessed by a single thread, even in multi-threaded programs. Each
> object is associated with an owning thread (the thread that created it). Reference counting operations from the owning thread use non-atomic
> instructions to modify a “local” reference count. Other threads use atomic instructions to modify a “shared” reference count. This design avoids many
> atomic read-modify-write operations that are expensive on contemporary processors.

Biased reference counting adds two counters to each object: one for the thread that owns the object, and another for all the other threads. The counter
held by the owning thread is not atomic. However, when the owning thread's count reaches zero, the object is not automatically deallocated. Instead,
the owning thread merges its counter with the shared one. If the combined count is zero, the object is deallocated, otherwise all remaining reference
counting is done on the shared reference counter in an atomic (and thus slower) manner. 

That can't be the only way for an object to be deallocated, since other threads are capable of removing references to the object that were added by
the owning thread. To account for this, if the shared reference counter drops below zero (meaning non-owning threads have destroyed more references than
they have created), then whichever non-owning thread is responsible for making the shared reference count go negative places the object in a queue 
belonging to the owning thread. For each object in its queue, the owning thread then merges its own reference count and the shared reference count.
Just as in the previous case, if the merged reference count is zero, the object is deallocated, otherwise the program falls back to the slow,
fully atomic reference counting scheme.

## Other Changes
There are lots of other changes and optimizations described in [the PEP](https://peps.python.org/pep-0703/), but the upshot is that CPython without the GIL generally has a small but persistent performance hit in single-threaded programs, on the order of 5%-8%. In return, a lot of opportunities for thread-based parallelism are unlocked, both from Python and from C extension code. 

Whether the benefits of parallelism are worth the single-threaded cost is a matter of opinion, but Sam makes a convincing case in the PEP that in the real world, the GIL is often a significant barrier to writing software in Python, whereas it is unusual for a 5%-8% single-threaded slowdown to be the difference between acceptable and unacceptable performance. By excising the GIL now, developers can focus on adapting their code to make use of thread-based parallelism right away while CPython core developers can look into mitigating the modest performance hit.

## Key Takeaway
The main takeaway from this blog post should be that removing the GIL does not make Python less threadsafe. Python code that was threadsafe with the GIL will still be threadsafe without it; code that was unsafe with the GIL will still be unsafe. The GIL protects the interpreter state from being corrupted by non-threadsafe code, it does not and never did make such code safe. Although we can expect more threading bugs to come up after the GIL's excision than before, that's only because more code will be *written* to use multiple threads than before. But we shouldn't cripple the language to try to prevent people from misusing it. And with their preliminary acceptance of the PEP, the Python steering committee has recognized that the future of CPython is a future without the GIL.


