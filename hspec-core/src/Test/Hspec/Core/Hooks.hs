-- | Stability: provisional
module Test.Hspec.Core.Hooks (
  before
, before_
, beforeWith
, beforeAll
, beforeAll_
, beforeAllWith
, after
, after_
, afterAll
, afterAll_
, around
, around_
, aroundWith
, aroundAll_
) where

import           Prelude ()
import           Test.Hspec.Core.Compat

import           Control.Exception (SomeException, finally, throwIO, try, catch)
import           Control.Concurrent.MVar
import           Control.Concurrent.Async

import           Test.Hspec.Core.Example
import           Test.Hspec.Core.Tree
import           Test.Hspec.Core.Spec.Monad

-- | Run a custom action before every spec item.
before :: IO a -> SpecWith a -> Spec
before action = around (action >>=)

-- | Run a custom action before every spec item.
before_ :: IO () -> SpecWith a -> SpecWith a
before_ action = around_ (action >>)

-- | Run a custom action before every spec item.
beforeWith :: (b -> IO a) -> SpecWith a -> SpecWith b
beforeWith action = aroundWith $ \e x -> action x >>= e

-- | Run a custom action before the first spec item.
beforeAll :: IO a -> SpecWith a -> Spec
beforeAll action spec = do
  mvar <- runIO (newMVar Empty)
  before (memoize mvar action) spec

-- | Run a custom action before the first spec item.
beforeAll_ :: IO () -> SpecWith a -> SpecWith a
beforeAll_ action spec = do
  mvar <- runIO (newMVar Empty)
  before_ (memoize mvar action) spec

-- | Run a custom action with an argument before the first spec item.
beforeAllWith :: (b -> IO a) -> SpecWith a -> SpecWith b
beforeAllWith action spec = do
  mvar <- runIO (newMVar Empty)
  beforeWith (memoize mvar . action) spec

data Memoized a =
    Empty
  | Memoized a
  | Failed SomeException

memoize :: MVar (Memoized a) -> IO a -> IO a
memoize mvar action = do
  result <- modifyMVar mvar $ \ma -> case ma of
    Empty -> do
      a <- try action
      return (either Failed Memoized a, a)
    Memoized a -> return (ma, Right a)
    Failed _ -> throwIO (Pending Nothing (Just "exception in beforeAll-hook (see previous failure)"))
  either throwIO return result

-- | Run a custom action after every spec item.
after :: ActionWith a -> SpecWith a -> SpecWith a
after action = aroundWith $ \e x -> e x `finally` action x

-- | Run a custom action after every spec item.
after_ :: IO () -> SpecWith a -> SpecWith a
after_ action = after $ \_ -> action

-- | Run a custom action before and/or after every spec item.
around :: (ActionWith a -> IO ()) -> SpecWith a -> Spec
around action = aroundWith $ \e () -> action e

-- | Run a custom action after the last spec item.
afterAll :: ActionWith a -> SpecWith a -> SpecWith a
afterAll action spec = runIO (runSpecM spec) >>= fromSpecList . return . NodeWithCleanup action

-- | Run a custom action after the last spec item.
afterAll_ :: IO () -> SpecWith a -> SpecWith a
afterAll_ action = afterAll (\_ -> action)

-- | Run a custom action before and/or after every spec item.
around_ :: (IO () -> IO ()) -> SpecWith a -> SpecWith a
around_ action = aroundWith $ \e a -> action (e a)

-- | Run a custom action before and/or after every spec item.
aroundWith :: (ActionWith a -> ActionWith b) -> SpecWith a -> SpecWith b
aroundWith action = mapSpecItem action (modifyAroundAction action)

modifyAroundAction :: (ActionWith a -> ActionWith b) -> Item a -> Item b
modifyAroundAction action item@Item{itemExample = e} =
  item{ itemExample = \params aroundAction -> e params (aroundAction . action) }

-- | Wrap an action around the given spec.
aroundAll_ :: (IO () -> IO ()) -> SpecWith a -> SpecWith a
aroundAll_ action spec = do
  startCleanup <- runIO newEmptyMVar
  workerRef <- runIO newEmptyMVar
  let
    acquire :: IO ()
    acquire = do
      acquireDone <- newEmptyMVar
      worker <- async $ do
        action $ do
          signal acquireDone
          waitFor startCleanup
      putMVar workerRef worker
      unwrapExceptionsFromLinkedThread $ do
        link worker
        waitFor acquireDone
    cleanup :: IO ()
    cleanup = signal startCleanup >> takeMVar workerRef >>= wait
  beforeAll_ acquire $ afterAll_ cleanup spec
  where
    signal :: MVar () -> IO ()
    signal = flip putMVar ()

    waitFor :: MVar () -> IO ()
    waitFor = takeMVar

    unwrapExceptionsFromLinkedThread :: IO a -> IO a
    unwrapExceptionsFromLinkedThread = (`catch` \ (ExceptionInLinkedThread _ e) -> throwIO e)
