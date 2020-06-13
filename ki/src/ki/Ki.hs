{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}

-- The only reason it module exists is:
--
-- 1. Haddock doesn't show reexported-modules
-- 2. Even if it did, haddock doesn't seem to preserve comments through
--    backpack signatures
module Ki
  ( -- * Context
    Context,
    background,
    cancelled,
    cancelledSTM,

    -- * Scope
    Scope,
    scoped,
    wait,
    waitSTM,
    waitFor,
    cancel,

    -- * Thread
    Thread,
    async,
    asyncWithUnmask,
    fork,
    forkWithUnmask,
    await,
    awaitSTM,
    awaitFor,
    kill,

    -- * Exceptions
    K.Cancelled (Cancelled),

    -- * Miscellaneous
    Seconds,
    timeout,
  )
where

import Control.Exception (SomeException)
import Data.Coerce (coerce)
import Data.Data (Data)
import GHC.Conc (STM)
import GHC.Generics (Generic)
import qualified Ki.Indef as K

-- | A 'Cancelled' exception is thrown when a __thread__ voluntarily capitulates after observing its __context__ is
-- /cancelled/.
pattern Cancelled :: K.Cancelled
pattern Cancelled <- K.Cancelled_ _

{-# COMPLETE Cancelled #-}

-- | A __context__ models a program's call tree, and is used as a mechanism to propagate /cancellation requests/ to
-- every __thread__ forked within a __scope__.
--
-- Every __thread__ is provided its own __context__, which is derived from its __scope__, and should replace any other
-- __context__ variable that may be in scope.
--
-- A __thread__ can query whether its __context__ has been /cancelled/, which is a suggestion to perform a graceful
-- termination.
--
-- === Usage summary
--
--   * A __context__ is /introduced by/ 'background', 'async', and 'fork'.
--   * A __context__ is /queried by/ 'cancelled'.
--   * A __context__ is /manipulated by/ 'cancel'.
newtype Context
  = Context K.Context
  deriving stock (Generic)

-- | A __scope__ delimits the lifetime of all __threads__ forked within it. A __thread__ cannot outlive its __scope__.
--
-- When a __scope__ is /closed/, all remaining __threads__ forked within it are killed.
--
-- The basic usage of a __scope__ is as follows.
--
-- @
-- 'scoped' context \\scope -> do
--   'fork' scope worker1
--   'fork' scope worker2
--   'wait' scope
-- @
--
-- A __scope__ can be passed into functions or shared amongst __threads__, but this is generally not advised, as it
-- takes the "structure" out of "structured concurrency".
--
-- === Usage summary
--
--   * A __scope__ is /introduced by/ 'scoped'.
--   * A __scope__ is /queried by/ 'wait'.
--   * A __scope__ is /manipulated by/ 'cancel'.
newtype Scope
  = Scope K.Scope

newtype Seconds
  = Seconds K.Seconds
  deriving stock (Data, Generic)
  deriving newtype (Enum, Eq, Fractional, Num, Ord, Read, Real, RealFrac, Show)

-- | A running __thread__.
--
-- === Usage summary
--
--   * A __thread__ is /introduced by/ 'async'.
--   * A __thread__ is /queried by/ 'await'.
--   * A __thread__ is /manipulated by/ 'kill'.
newtype Thread a
  = Thread (K.Thread a)
  deriving stock (Generic)
  deriving newtype (Eq, Ord)

-- | Fork a __thread__ within a __scope__. The derived __context__ should replace the usage of any other __context__ in
-- scope.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
async :: Scope -> (Context -> IO a) -> IO (Thread a)
async = _async
{-# INLINE async #-}

_async :: forall a. Scope -> (Context -> IO a) -> IO (Thread a)
_async = coerce @(K.Scope -> (K.Context -> IO a) -> IO (K.Thread a)) K.async
{-# INLINE _async #-}

-- | Variant of 'async' that provides the __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
asyncWithUnmask :: Scope -> (Context -> (forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
asyncWithUnmask = _asyncWithUnmask
{-# INLINE asyncWithUnmask #-}

_asyncWithUnmask :: forall a. Scope -> (Context -> (forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
_asyncWithUnmask scope k =
  coerce
    @(IO (K.Thread a))
    (K.asyncWithUnmask (coerce scope) \context -> k (coerce context))
{-# INLINE _asyncWithUnmask #-}

-- | Wait for a __thread__ to finish.
await :: Thread a -> IO (Either SomeException a)
await = _await
{-# INLINE await #-}

_await :: forall a. Thread a -> IO (Either SomeException a)
_await = coerce @(K.Thread a -> IO (Either SomeException a)) K.await
{-# INLINE _await #-}

-- | Variant of 'await' that gives up after the given number of seconds elapses.
--
-- @
-- 'awaitFor' thread seconds =
--   'timeout' seconds (pure . Just \<$\> 'awaitSTM' thread) (pure Nothing)
-- @
awaitFor :: Thread a -> Seconds -> IO (Maybe (Either SomeException a))
awaitFor = _awaitFor
{-# INLINE awaitFor #-}

_awaitFor :: forall a. Thread a -> Seconds -> IO (Maybe (Either SomeException a))
_awaitFor = coerce @(K.Thread a -> K.Seconds -> IO (Maybe (Either SomeException a))) K.awaitFor
{-# INLINE _awaitFor #-}

-- | @STM@ variant of 'await'.
--
-- /Throws/:
--
--   * The exception that the __thread__ threw, if any.
awaitSTM :: Thread a -> STM (Either SomeException a)
awaitSTM = _awaitSTM
{-# INLINE awaitSTM #-}

_awaitSTM :: forall a. Thread a -> STM (Either SomeException a)
_awaitSTM = coerce @(K.Thread a -> STM (Either SomeException a)) K.awaitSTM
{-# INLINE _awaitSTM #-}

-- | The background __context__.
--
-- You should only use this when another __context__ isn't available, as when creating a top-level __scope__ from the
-- main thread.
--
-- The background __context__ cannot be /cancelled/.
background :: Context
background = coerce K.background
{-# INLINE background #-}

-- | /Cancel/ all __contexts__ derived from a __scope__.
cancel :: Scope -> IO ()
cancel = coerce K.cancel
{-# INLINE cancel #-}

-- | Return whether a __context__ is /cancelled/.
--
-- __Threads__ running in a /cancelled/ __context__ should terminate as soon as possible. The returned action may be
-- used to honor the /cancellation/ request in case the __thread__ is unable or unwilling to terminate normally with a
-- value.
--
-- ==== __Examples__
--
-- Sometimes, a __thread__ may terminate with a value after observing a cancellation request.
--
-- @
-- 'cancelled' context >>= \\case
--   Nothing -> continue
--   Just _capitulate -> do
--     cleanup
--     pure value
-- @
--
-- Other times, it may be unable to, so it should call the provided action.
--
-- @
-- 'cancelled' context >>= \\case
--   Nothing -> continue
--   Just capitulate -> do
--     cleanup
--     capitulate
-- @
cancelled :: Context -> IO (Maybe (IO a))
cancelled = _cancelled
{-# INLINE cancelled #-}

_cancelled :: forall a. Context -> IO (Maybe (IO a))
_cancelled = coerce @(K.Context -> IO (Maybe (IO a))) K.cancelled
{-# INLINE _cancelled #-}

-- | @STM@ variant of 'cancelled'.
cancelledSTM :: Context -> STM (Maybe (IO a))
cancelledSTM = _cancelledSTM
{-# INLINE cancelledSTM #-}

_cancelledSTM :: forall a. Context -> STM (Maybe (IO a))
_cancelledSTM = coerce @(K.Context -> STM (Maybe (IO a))) K.cancelledSTM
{-# INLINE _cancelledSTM #-}

-- | Variant of 'async' that does not return a handle to the __thread__.
--
-- If the forked __thread__ throws an /unexpected/ exception, the exception is propagated up the call tree to the
-- __thread__ that opened its __scope__.
--
-- There is one /expected/ exceptions a __thread__ may throw that will not be propagated up the call tree:
--
--   * 'Cancelled', as when a __thread__ voluntarily capitulates after observing a /cancellation/ request.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork :: Scope -> (Context -> IO ()) -> IO ()
fork = coerce @(K.Scope -> (K.Context -> IO ()) -> IO ()) K.fork
{-# INLINE fork #-}

-- | Variant of 'fork' that provides the __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask :: Scope -> (Context -> (forall x. IO x -> IO x) -> IO ()) -> IO ()
forkWithUnmask scope k =
  K.forkWithUnmask (coerce scope) \context -> k (coerce context)
{-# INLINE forkWithUnmask #-}

-- | Kill a __thread__ wait for it to finish.
--
-- /Throws/:
--
--   * 'ThreadKilled' if a __thread__ attempts to kill itself.
kill :: Thread a -> IO ()
kill = _kill
{-# INLINE kill #-}

_kill :: forall a. Thread a -> IO ()
_kill = coerce @(K.Thread a -> IO ()) K.kill
{-# INLINE _kill #-}

-- | Perform an action with a new __scope__, then /close/ the __scope__.
--
-- /Throws/:
--
--   * The first exception a __thread__ forked with 'fork' throws, if any.
--
-- ==== __Examples__
--
-- @
-- 'scoped' context \\scope -> do
--   'fork' scope worker1
--   'fork' scope worker2
--   'wait' scope
-- @
scoped :: Context -> (Scope -> IO a) -> IO a
scoped = _scoped
{-# INLINE scoped #-}

_scoped :: forall a. Context -> (Scope -> IO a) -> IO a
_scoped = coerce @(K.Context -> (K.Scope -> IO a) -> IO a) K.scoped
{-# INLINE _scoped #-}

-- | Wait for an @STM@ action to return, and return the @IO@ action contained within.
--
-- If the given number of seconds elapses, return the given @IO@ action instead.
timeout :: Seconds -> STM (IO a) -> IO a -> IO a
timeout = _timeout
{-# INLINE timeout #-}

_timeout :: forall a. Seconds -> STM (IO a) -> IO a -> IO a
_timeout = coerce @(K.Seconds -> STM (IO a) -> IO a -> IO a) K.timeout
{-# INLINE _timeout #-}

-- | Variant of 'wait' that gives up after the given number of seconds elapses.
--
-- @
-- 'waitFor' scope seconds =
--   'timeout' seconds (pure \<$\> 'waitSTM' scope) (pure ())
-- @
waitFor :: Scope -> Seconds -> IO ()
waitFor = coerce K.waitFor
{-# INLINE waitFor #-}

-- | Wait until all __threads__ forked within a __scope__ finish.
wait :: Scope -> IO ()
wait = coerce K.wait
{-# INLINE wait #-}

-- | @STM@ variant of 'wait'.
waitSTM :: Scope -> STM ()
waitSTM = coerce K.waitSTM
{-# INLINE waitSTM #-}
