module Ki.Thread
  ( Thread (..),
    await,
    awaitSTM,
    awaitFor,
    kill,

    -- * Internal API
    AsyncThreadFailed (..),
    unwrapAsyncThreadFailed,
  )
where

import Control.Exception (AsyncException (ThreadKilled), Exception (..), asyncExceptionFromException, asyncExceptionToException)
import Ki.Concurrency
import Ki.Prelude
import Ki.Seconds (Seconds)
import Ki.Timeout (timeoutSTM)

-- | A running __thread__.
data Thread a = Thread
  { threadId :: !ThreadId,
    action :: !(STM (Either SomeException a))
  }
  deriving stock (Functor, Generic)

instance Eq (Thread a) where
  Thread id1 _ == Thread id2 _ =
    id1 == id2

instance Ord (Thread a) where
  compare (Thread id1 _) (Thread id2 _) =
    compare id1 id2

-- | Wait for a __thread__ to finish.
await :: Thread a -> IO (Either SomeException a)
await =
  atomically . awaitSTM

-- | @STM@ variant of 'await'.
--
-- /Throws/:
--
--   * The exception that the __thread__ threw, if any.
awaitSTM :: Thread a -> STM (Either SomeException a)
awaitSTM Thread {action} =
  action

-- | Variant of 'await' that gives up after the given number of seconds elapses.
--
-- @
-- 'awaitFor' thread seconds =
--   'timeout' seconds (pure . Just \<$\> 'awaitSTM' thread) (pure Nothing)
-- @
awaitFor :: Thread a -> Seconds -> IO (Maybe (Either SomeException a))
awaitFor thread seconds =
  timeoutSTM seconds (pure . Just <$> awaitSTM thread) (pure Nothing)

-- | Kill a __thread__ wait for it to finish.
--
-- /Throws/:
--
--   * 'ThreadKilled' if a __thread__ attempts to kill itself.
kill :: Thread a -> IO ()
kill thread = do
  throwTo (threadId thread) ThreadKilled
  void (await thread)

newtype AsyncThreadFailed
  = AsyncThreadFailed SomeException
  deriving stock (Show)

instance Exception AsyncThreadFailed where
  fromException = asyncExceptionFromException
  toException = asyncExceptionToException

unwrapAsyncThreadFailed :: SomeException -> SomeException
unwrapAsyncThreadFailed ex =
  case fromException ex of
    Just (AsyncThreadFailed exception) -> exception
    _ -> ex
