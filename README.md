# gen_rpc: A scalable RPC library for Erlang-VM based languages

## Overview

- Latest release: ![Tag Version](https://img.shields.io/github/tag/priestjim/gen_rpc.svg)
- Branch status (`master`): [![Build Status](https://travis-ci.org/priestjim/gen_rpc.svg?branch=master)](https://travis-ci.org/priestjim/gen_rpc) [![Coverage Status](https://coveralls.io/repos/priestjim/gen_rpc/badge.svg?branch=master&service=github)](https://coveralls.io/github/priestjim/gen_rpc?branch=master)
- Branch status (`develop`): [![Build Status](https://travis-ci.org/priestjim/gen_rpc.svg?branch=develop)](https://travis-ci.org/priestjim/gen_rpc) [![Coverage Status](https://coveralls.io/repos/priestjim/gen_rpc/badge.svg?branch=develop&service=github)](https://coveralls.io/github/priestjim/gen_rpc?branch=develop)
- Issues: [![GitHub issues](https://img.shields.io/github/issues/priestjim/gen_rpc.svg)](https://github.com/priestjim/gen_rpc/issues)
- License: [![GitHub license](https://img.shields.io/badge/license-Apache%202-blue.svg)](https://raw.githubusercontent.com/priestjim/gen_rpc/master/LICENSE)
- [Erlang Factory 2016 Talk](https://www.youtube.com/watch?feature=player_embedded&v=xiPnLACtNeo)

## Rationale

**TL;DR**: `gen_rpc` uses a mailbox-per-node architecture and `gen_tcp` processes to parallelize data reception from multiple nodes without blocking the VM's distributed port.

The reasons for developing `gen_rpc` became apparent after a lot of trial and error while trying to scale a distributed Erlang infrastructure using the `rpc` library initially and subsequently `erlang:spawn/4` (remote spawn). Both these solutions suffer from very specific issues under a sufficiently high number of requests.

The `rpc` library operates by shipping data over the wire via Distributed Erlang's ports into a registered `gen_server` on the other side called `rex` (Remote EXecution server), which is running as part of the standard distribution. In high traffic scenarios, this allows the inherent problem of running a single `gen_server` server to manifest: mailbox flooding. As the number of nodes participating in a data exchange with the node in question increases, so do the messages that `rex` has to deal with, eventually becoming too much for the process to handle (don't forget this is confined to a single thread).

Enter `erlang:spawn/4` (_remote spawn_ from now on). Remote spawn dynamically spawns processes on a remote node, skipping the single-mailbox restriction that `rex` has. The are various libraries written to leverage that loophole (such as [Rexi](https://github.com/cloudant/rexi)), however there's a catch.

Remote spawn was not designed to ship large amounts of data as part of the call's arguments. Hence, if you want to ship a large binary such as a picture or a transaction log (large can also be small if your network is slow) over remote spawn, sooner or later you'll see this message popping up in your logs if you have subscribed to the system monitor through `erlang:system_monitor/2`:

```erlang
{monitor,<4685.187.0>,busy_dist_port,#Port<4685.41652>}
```

This message essentially means that the VM's distributed port pair was busy while the VM was trying to use it for some other task like _Distributed Erlang heartbeat beacons_ or _mnesia synchronization_. This of course wrecks havoc in certain timing expectations these subsystems have and the results can be very problematic: the VM might detect a node as disconnected even though everything is perfectly healthy and `mnesia` might misdetect a network partition.

`gen_rpc` solves both these problems by sharding data coming from different nodes to different processes (hence different mailboxes) and by using different `gen_tcp` ports for different nodes (hence not utilizing the Distributed Erlang ports).

# Build Dependencies

To build this project you need to have the following:

* **Erlang/OTP** >= 17.0

* **git** >= 1.7

* **GNU make** >= 3.80

* **rebar3** >= 3.0-beta4

## Usage

Getting started with `gen_rpc` is easy. First, add the appropriate dependency line to your `rebar.config`:

```erlang
{deps, [
    {gen_rpc, {git, "https://github.com/priestjim/gen_rpc.git", {branch, "master"}}}
]}.
```

Or if you're using `hex.pm`:

```erlang
{deps [
    {gen_rpc, "1.0.2"}
]}.
```

Or if you're using Elixir/Mix:

```elixir
def project do
  [
    deps: [
      {:gen_rpc, "~> 1.0.0"}
    ]
  ]
```

Then, add `gen_rpc` as a dependency application to your `.app.src`/`.app` file:

```erlang
{application, my_app, [
    {applications, [kernel, stdlib, gen_rpc]}
]}
```

Or your `mix.exs` file:

```elixir
def application do
  applications: [:gen_rpc]
end
```

Finally, start a couple of nodes to test it out:

```erlang
(my_app@127.0.0.1)1> gen_rpc:call('other_node@1.2.3.4', erlang, node, []).
'other_node@1.2.3.4'
```

## Build Targets

`gen_rpc` bundles a `Makefile` that makes development straightforward.

To build `gen_rpc` simply run:

    make

To run the full test suite, run:

    make test

To run the full test suite, the XRef tool and Dialyzer, run:

    make dist

To build the project and drop in a console while developing, run:

    make shell

To clean every build artifact and log, run:

    make distclean

## Testing

A full suite of tests has been implemented for `gen_rpc`. You can run the CT-based test suite, dialyzer and xref by:

    make dist

If you have **Docker** available on your system, you can run dynamic integration tests with "physically" separated hosts/nodes
by running the command:

    make integration

This will launch 3 slave containers and 1 master (change that by `NODES=5 make integration`) and will run the `integration_SUITE` CT test suite.

## API

`gen_rpc` implements only the subset of the functions of the `rpc` library that make sense for the problem it's trying to solve. The library's function interface and return values is **100%** compatible with `rpc` with only one addition: Error return values include `{badrpc, Error}` for RPC-based errors but also `{badtcp, Error}` for TCP-based errors.

For more information on what the functions below do, run `erl -man rpc`.

### Functions exported

- `call(Node, Module, Function, Args)` and `call(Node, Module, Function, Args, Timeout)`: A blocking synchronous call, in the `gen_server` fashion.

- `cast(Node, Module, Function, Args)`: A non-blocking fire-and-forget call.

- `async_call(Node, Module, Function, Args)`, `yield(Key)`, `nb_yield(Key)` and `nb_yield(Key, Timeout)`: Promise-based calls. Make a call with `async_call` and retrieve the result asynchronously, when you need it with `yield` or `nb_yield`.

- `multicall(Module, Function, Args)`, `multicall(Nodes, Module, Function, Args)`, `multicall(Module, Function, Args, Timeout)` and `multicall(Nodes, Module, Function, Args, Timeout)`: Multi-node version of the `call` function.

- `abcast(Nodes, Name, Msg)` and `abcast(Name, Msg)`: An asynchronous broadcast function, sending the message `Msg` to the named process `Name` in all the nodes in `Nodes`.

- `sbcast(Nodes, Name, Msg)` and `sbcast(Name, Msg)`: A synchronous broadcast function, sending the message `Msg` to the named process `Name` in all the nodes in `Nodes`. Returns the nodes in which the named process is alive and the nodes in which it isn't.

- `eval_everywhere(Module, Function, Args)` and `eval_everywhere(Nodes, Module, Function, Args)`: Multi-node version of the `cast` function.

### Application settings

- `tcp_server_port`: The port in which the TCP listener service listens for incoming client requests.

- `remote_tcp_server_ports`: A proplist with the nodes that run on alternative `tcp_server_port` configuration and the port
  they have configured `gen_rpc` to listen to. Useful when running multiple nodes on the same system and you get port clashes.

- `rpc_module_control`: Set it to `blacklist` to define a list of modules that will not be exposed to `gen_rpc` or to `whitelist`
  to define the list of modules that will be exposed to `gen_rpc`. Set it to `undefined` to disable this feature.

- `rpc_module_list`: The list of modules that are going to be blacklisted or whitelisted.

- `connect_timeout`: Default timeout for the initial node-to-node connection in **milliseconds**.

- `send_timeout`: Default timeout for the transmission of a request (`call`/`cast` etc.) from the local node to the remote node in **milliseconds**.

- `call_receive_timeout`: Default timeout for the reception of a response in a `call` in **milliseconds**.

- `sbcast_receive_timeout`: Default timeout for the reception of a response in an `sbcast` in **milliseconds**.

- `client_inactivity_timeout`: Inactivity period in **milliseconds** after which a client connection to a node will be closed (and hence have the TCP file descriptor freed).

- `server_inactivity_timeout`: Inactivity period in **milliseconds** after which a server port will be closed (and hence have the TCP file descriptor freed).

- `async_call_inactivity_timeout`: Inactivity period in **milliseconds** after which a pending process holding an `async_call` return value will exit. This is used for process sanitation purposes so please make sure to set it in a sufficiently high number (or `infinity`).

## Architecture

In order to achieve the mailbox-per-node feature, `gen_rpc` uses a very specific architecture:

- Whenever a client needs to send data to a remote node, it will perform a `whereis` to a process named after the remote node.

- If the specified `client` process does not exist, it will request for a new one through the `dispatcher` process, which in turn will launch it through the appropriate `client` supervisor. Since this |`whereis` > request from dispatcher sequence > start client| can happen concurrently by many different processes, serializing it behind a `gen_server` allows us to avoid race conditions.

- The `dispatcher` process will launch a new `client` process through the client's supervisor.

- The new client process will connect to the remote node's `tcp listener`, submit a requeset for a new server and wait.

- The `tcp listener` server will ask the `server` supervisor to launch a new `server` process, which in turn will dynamically allocate (`gen_tcp:listen(0)`) a port and return it.

- The `server` supervisor returns the port to the `tcp listener` which in turn returns it to the `client` through the TCP channel.

- The `server` then shuts down the TCP channel as its purpose has been fullfilled (which also minimizes file descriptor usage).

- The `client` then connects to the returned port and establishes a TCP session. The `server` on the other node launches a new `acceptor` server as soon as a `client` connects. The relationship between `client`-`server`-`acceptor` is one-to-one-to-one.

- The `client` finally encodes the request (`call`, `cast` etc.) along with some metadata (the caller's PID and a reference) and sends it over the TCP channel. In case of an `async call`, the `client` also launches a process that will be responsible for handing the server's reply to the requester.

- The `server` on the other side decodes the TCP message received and spawns a new process that will perform the requested function. By spawning a process external to the server, the `server` protects itself from misbehaving function calls.

- As soon as the reply from the server is ready (only needed in `async_call` and `call`), the `server` spawned process messages the server with the reply, the `server` ships it through the TCP channel to the `client` and the client send the message back to the requester. In the case of `async call`, the `client` messages the spawned worker and the worker replies to the caller with the result.

All `gen_tcp` processes are properly linked so that any TCP failure will cascade and close the TCP channels and any new connection will allocate a new process and port.

An inactivity timeout has been implemented inside the `client` and `server` processes to free unused TCP connections after some time, in case that's needed.

## Performance

`gen_rpc` is being used in production extensively with over **150.000 incoming calls/sec/node** on a **8-core Intel Xeon E5** CPU and **Erlang 18.2**. The median payload size is **500 KB**. No stability or scalability issues have been detected in over a year.

## Known Issues

- When shipping an anonymous function over to another node, it will fail to execute because of the way Erlang implements anonymous functions (Erlang serializes the function metadata but not the function body). This issue also exists in both `rpc` and remote spawn.

## Licensing

This project is published and distributed under the [Apache License](LICENSE).

## Contributing

Please see [CONTRIBUTING.md](CONTRIBUTING.md)

### Contributors:

- [Edward Tsang](https://github.com/linearregression)
