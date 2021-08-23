module Ki.Scope
  ( Scope (..),
    ScopeClosing (..),
    scopeFork,
    scoped,
    wait,
    waitFor,
    waitSTM,
    --
    async,
    asyncWithUnmask,
    await,
    awaitFor,
    awaitSTM,
    fork,
    fork_,
    forkWithUnmask,
    forkWithUnmask_,
    Thread (..),
    ThreadFailed (..),
  )
where

import Control.Exception
  ( BlockedIndefinitelyOnSTM (..),
    Exception (fromException, toException),
    SomeAsyncException,
    asyncExceptionFromException,
    asyncExceptionToException,
    catch,
    pattern ErrorCall,
  )
import Control.Monad.IO.Unlift (MonadUnliftIO (withRunInIO))
import Data.Function (on)
import qualified Data.IntMap.Strict as IntMap
import Data.Maybe (isJust)
import qualified Data.Monoid as Monoid
import Data.Ord (comparing)
import Ki.Duration (Duration)
import Ki.Prelude
import Ki.Timeout

------------------------------------------------------------------------------------------------------------------------
-- Scope

-- | A __scope__ delimits the lifetime of all __threads__ created within it.
data Scope = Scope
  { -- | The set of child threads that are currently running, each keyed by a monotonically increasing int.
    childrenVar :: {-# UNPACK #-} !(TVar (IntMap ThreadId)),
    -- | The key to use for the next child thread.
    nextChildIdVar :: {-# UNPACK #-} !(TVar Int),
    -- | The number of child threads that are guaranteed to be about to start, in the sense that only the GHC scheduler
    -- can continue to delay; no async exception can strike here and prevent one of these threads from starting.
    --
    -- Sentinel value: -1 means the scope is closed.
    startingVar :: {-# UNPACK #-} !(TVar Int)
  }

-- | Exception thrown by a parent __thread__ to its children when its __scope__ is closing.
data ScopeClosing
  = ScopeClosing
  deriving stock (Eq, Show)

instance Exception ScopeClosing where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

scopeFork :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> (Either SomeException a -> IO ()) -> IO ThreadId
scopeFork Scope {childrenVar, nextChildIdVar, startingVar} action k =
  uninterruptibleMask \restore -> do
    -- Record the thread as being about to start, and grab an id for it
    childId <-
      atomically do
        starting <- readTVar startingVar
        if starting == -1
          then throwSTM (ErrorCall "ki: scope closed")
          else do
            childId <- readTVar nextChildIdVar
            writeTVar nextChildIdVar $! childId + 1
            writeTVar startingVar $! starting + 1
            pure childId

    childThreadId <-
      forkIO do
        result <- try (action restore)
        -- Perform the internal callback (this is where we decide to propagate the exception and whatnot)
        k result
        -- Delete ourselves from the scope's record of what's running. Why not just IntMap.delete? It might miss (race
        -- condition) - we wouldn't want to delete *nothing*, *then* insert from the parent thread. So just retry until
        -- the parent has recorded us as having started.
        atomically do
          children <- readTVar childrenVar
          case IntMap.alterF (maybe Nothing (const (Just Nothing))) childId children of
            Nothing -> retry
            Just running -> writeTVar childrenVar running

    -- Record the thread as having started
    atomically do
      modifyTVar' startingVar \n -> n -1
      modifyTVar' childrenVar (IntMap.insert childId childThreadId)

    pure childThreadId

-- | Open a __scope__, perform an action with it, then close the __scope__.
--
-- When the __scope__ is closed, all remaining __threads__ created within it are thrown an asynchronous exception in the
-- order they were created, and FIXME we block until they all terminate.
--
-- ==== __Examples__
--
-- @
-- 'Ki.scoped' \\scope -> do
--   'Ki.fork_' scope worker1
--   'Ki.fork_' scope worker2
--   'Ki.wait' scope
-- @
scoped :: MonadUnliftIO m => (Scope -> m a) -> m a
scoped action =
  withRunInIO \unlift -> scopedIO (unlift . action)
{-# INLINE scoped #-}
{-# SPECIALIZE scoped :: (Scope -> IO a) -> IO a #-}

scopedIO :: (Scope -> IO a) -> IO a
scopedIO f = do
  childrenVar <- newTVarIO IntMap.empty
  nextChildIdVar <- newTVarIO 0
  startingVar <- newTVarIO 0
  let scope = Scope {childrenVar, nextChildIdVar, startingVar}

  uninterruptibleMask \restore -> do
    result <- try (restore (f scope))

    children <-
      atomically do
        -- Block until we haven't committed to starting any threads. Without this, we may create a thread concurrently
        -- with closing its scope, and not grab its thread id to throw an exception to.
        blockUntilNoneStarting scope
        -- Write the sentinel value indicating that this scope is closed, and it is an error to try to create a thread
        -- within it.
        writeTVar startingVar (-1)
        -- Return the list of currently-running children to kill. Some of them may have *just* started (e.g. if we
        -- initially retried in 'blockUntilNoneStarting' above). That's fine - kill them all!
        readTVar childrenVar

    -- Deliver an async exception to every child. While doing so, we may get hit by an async exception ourselves, which
    -- we don't want to just ignore. (Actually, we may have been hit by an arbitrary number of async exceptions,
    -- but it's unclear what we would do with such a list, so we only remember the first one, and ignore the others).
    firstExceptionReceivedWhileKillingChildren <- killThreads (IntMap.elems children)

    -- Block until all children have terminated; this relies on children respecting the async exception, which they
    -- must, for correctness. Otherwise, a thread could indeed outlive the scope in which it's created, which is
    -- definitely not structured concurrency!
    atomically (blockUntilNoneRunning scope)

    -- If the callback failed, we don't care if we were thrown an async exception while closing the scope. Otherwise,
    -- throw that exception (if it exists).
    case result of
      Left exception -> throw exception
      Right value -> do
        whenJust firstExceptionReceivedWhileKillingChildren throw
        pure value
  where
    -- If applicable, unwrap the 'ThreadFailed' (assumed to have come from one of our children).
    throw :: SomeException -> IO a
    throw exception =
      case fromException exception of
        Just (ThreadFailed threadFailedException) -> throwIO threadFailedException
        Nothing -> throwIO exception

    -- In the order they were created, throw a 'ScopeClosing' exception to each of the given threads.
    --
    -- FIXME better docs, and unsafeUnmask in forked thread propagating instead?
    killThreads :: [ThreadId] -> IO (Maybe SomeException)
    killThreads =
      (`fix` mempty) \loop !acc -> \case
        [] -> pure (Monoid.getFirst acc)
        threadId : threadIds ->
          -- We unmask because we don't want to deadlock with a thread
          -- that is concurrently trying to throw an exception to us with
          -- exceptions masked.
          try (unsafeUnmask (throwTo threadId ScopeClosing)) >>= \case
            -- don't drop thread we didn't (necessarily) deliver the exception to
            Left exception -> loop (acc <> Monoid.First (Just exception)) (threadId : threadIds)
            Right () -> loop acc threadIds

-- | Wait until all __threads__ created within a __scope__ terminate.
wait :: MonadIO m => Scope -> m ()
wait =
  liftIO . atomically . waitSTM
{-# INLINE wait #-}
{-# SPECIALIZE wait :: Scope -> IO () #-}

-- | Variant of 'Ki.wait' that waits for up to the given duration.
waitFor :: MonadIO m => Scope -> Duration -> m ()
waitFor scope duration =
  liftIO (timeoutSTM duration (pure <$> waitSTM scope) (pure ()))
{-# INLINE waitFor #-}
{-# SPECIALIZE waitFor :: Scope -> Duration -> IO () #-}

-- | @STM@ variant of 'Ki.wait'.
waitSTM :: Scope -> STM ()
waitSTM scope = do
  blockUntilNoneRunning scope
  blockUntilNoneStarting scope
{-# INLINE waitSTM #-}

-- | Block until no children are running.
blockUntilNoneRunning :: Scope -> STM ()
blockUntilNoneRunning Scope {childrenVar} = do
  children <- readTVar childrenVar
  when (not (IntMap.null children)) retry

-- | Block until no children are guaranteed to start soon.
blockUntilNoneStarting :: Scope -> STM ()
blockUntilNoneStarting Scope {startingVar} = do
  starting <- readTVar startingVar
  when (starting > 0) retry

------------------------------------------------------------------------------------------------------------------------
-- Thread

-- | A running __thread__.
data Thread a = Thread
  { await_ :: !(STM a),
    thread'Id :: {-# UNPACK #-} !ThreadId
  }
  deriving stock (Functor)

instance Eq (Thread a) where
  (==) =
    (==) `on` thread'Id

instance Ord (Thread a) where
  compare =
    comparing thread'Id

-- | Exception thrown by a child __thread__ to its parent, if it fails unexpectedly.
newtype ThreadFailed
  = ThreadFailed SomeException
  deriving stock (Show)

instance Exception ThreadFailed where
  toException = asyncExceptionToException
  fromException = asyncExceptionFromException

-- | Create a child __thread__ within a __scope__.
async :: MonadUnliftIO m => Scope -> m a -> m (Thread (Either SomeException a))
async scope action =
  withRunInIO \unlift ->
    asyncWithRestore scope \restore ->
      restore (unlift action)
{-# INLINE async #-}
{-# SPECIALIZE async :: Scope -> IO a -> IO (Thread (Either SomeException a)) #-}

-- | Variant of 'Ki.async' that provides the __thread__ a function that unmasks asynchronous exceptions.
asyncWithUnmask ::
  MonadUnliftIO m =>
  Scope ->
  ((forall x. m x -> m x) -> m a) ->
  m (Thread (Either SomeException a))
asyncWithUnmask scope action =
  withRunInIO \unlift ->
    asyncWithRestore scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE asyncWithUnmask #-}
{-# SPECIALIZE asyncWithUnmask ::
  Scope ->
  ((forall x. IO x -> IO x) -> IO a) ->
  IO (Thread (Either SomeException a))
  #-}

asyncWithRestore :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread (Either SomeException a))
asyncWithRestore scope action = do
  parentThreadId <- myThreadId
  resultVar <- newEmptyTMVarIO
  thread'Id <-
    scopeFork scope action \result -> do
      -- FIXME should we put or propagate first?
      case result of
        Left exception -> maybePropagateException scope parentThreadId exception isAsyncException
        Right _ -> pure ()
      putTMVarIO resultVar result -- even put async exceptions that we propagated
  pure
    Thread
      { await_ = readTMVar resultVar,
        thread'Id
      }
  where
    isAsyncException :: SomeException -> Bool
    isAsyncException =
      isJust . fromException @SomeAsyncException

-- | Wait for a __thread__ to terminate.
await :: MonadIO m => Thread a -> m a
await thread =
  -- If *they* are deadlocked, we will *both* will be delivered a wakeup from the RTS. We want to shrug this exception
  -- off, because afterwards they'll have put to the result var. But don't shield indefinitely, once will cover this use
  -- case and prevent any accidental infinite loops.
  liftIO (go `catch` \BlockedIndefinitelyOnSTM -> go)
  where
    go =
      atomically (await_ thread)
{-# INLINE await #-}
{-# SPECIALIZE await :: Thread a -> IO a #-}

-- | Variant of 'Ki.await' that gives up after the given duration.
awaitFor :: MonadIO m => Thread a -> Duration -> m (Maybe a)
awaitFor thread duration =
  liftIO (timeoutSTM duration (pure . Just <$> await_ thread) (pure Nothing))
{-# INLINE awaitFor #-}
{-# SPECIALIZE awaitFor :: Thread a -> Duration -> IO (Maybe a) #-}

-- | @STM@ variant of 'Ki.await'.
awaitSTM :: Thread a -> STM a
awaitSTM =
  await_

-- | Create a child __thread__ within a __scope__.
--
-- If the child __thread__ throws an exception, the exception is immediately propagated to its parent __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork :: MonadUnliftIO m => Scope -> m a -> m (Thread a)
fork scope action =
  withRunInIO \unlift ->
    forkWithRestore scope \restore ->
      restore (unlift action)
{-# INLINE fork #-}
{-# SPECIALIZE fork :: Scope -> IO a -> IO (Thread a) #-}

-- | Variant of 'Ki.fork' that does not return a handle to the child __thread__.
--
-- If the child __thread__ throws an exception, the exception is immediately propagated to its parent __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
fork_ :: MonadUnliftIO m => Scope -> m () -> m ()
fork_ scope action =
  withRunInIO \unlift ->
    forkWithRestore_ scope \restore ->
      restore (unlift action)
{-# INLINE fork_ #-}
{-# SPECIALIZE fork_ :: Scope -> IO () -> IO () #-}

-- | Variant of 'Ki.fork' that provides the child __thread__ a function that unmasks asynchronous exceptions.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask :: MonadUnliftIO m => Scope -> ((forall x. m x -> m x) -> m a) -> m (Thread a)
forkWithUnmask scope action =
  withRunInIO \unlift ->
    forkWithRestore scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE forkWithUnmask #-}
{-# SPECIALIZE forkWithUnmask ::
  Scope ->
  ((forall x. IO x -> IO x) -> IO a) ->
  IO (Thread a)
  #-}

-- | Variant of 'Ki.forkWithUnmask' that does not return a handle to the child __thread__.
--
-- /Throws/:
--
--   * Calls 'error' if the __scope__ is /closed/.
forkWithUnmask_ :: MonadUnliftIO m => Scope -> ((forall x. m x -> m x) -> m ()) -> m ()
forkWithUnmask_ scope action =
  withRunInIO \unlift ->
    forkWithRestore_ scope \restore ->
      restore (unlift (action (liftIO . unsafeUnmask . unlift)))
{-# INLINE forkWithUnmask_ #-}
{-# SPECIALIZE forkWithUnmask_ ::
  Scope ->
  ((forall x. IO x -> IO x) -> IO ()) ->
  IO ()
  #-}

forkWithRestore :: Scope -> ((forall x. IO x -> IO x) -> IO a) -> IO (Thread a)
forkWithRestore scope action = do
  parentThreadId <- myThreadId
  resultVar <- newEmptyTMVarIO
  thread'Id <-
    scopeFork scope action \result -> do
      case result of
        Left exception -> maybePropagateException scope parentThreadId exception (const True)
        Right _ -> pure ()
      -- even put async exceptions that we propagated
      -- this isn't totally ideal because a caller awaiting this thread would not be able to distinguish between async
      -- exceptions delivered to this thread, or itself
      putTMVarIO resultVar result
  pure
    Thread
      { await_ = readTMVar resultVar >>= either throwSTM pure,
        thread'Id
      }

forkWithRestore_ :: Scope -> ((forall x. IO x -> IO x) -> IO ()) -> IO ()
forkWithRestore_ scope action = do
  parentThreadId <- myThreadId
  _childThreadId <-
    scopeFork scope action \case
      Left exception -> maybePropagateException scope parentThreadId exception (const True)
      Right () -> pure ()
  pure ()

maybePropagateException :: Scope -> ThreadId -> SomeException -> (SomeException -> Bool) -> IO ()
maybePropagateException scope parentThreadId exception should =
  whenM shouldPropagateException (throwTo parentThreadId (ThreadFailed exception))
  where
    shouldPropagateException :: IO Bool
    shouldPropagateException
      -- Our scope is (presumably) closing, so don't propagate this exception that (presumably) just came from our
      -- parent. But if our scope's not closed, that means this 'ScopeClosing' definitely came from somewhere else...
      | Just ScopeClosing <- fromException exception = (/= -1) <$> readTVarIO (startingVar scope)
      | otherwise = pure (should exception)
