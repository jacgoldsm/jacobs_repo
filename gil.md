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
