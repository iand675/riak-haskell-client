{-# LANGUAGE BangPatterns, DeriveDataTypeable, GeneralizedNewtypeDeriving #-}
-- |
-- Module:      Network.Riak.Resolvable.Internal
-- Copyright:   (c) 2011 MailRank, Inc.
-- License:     Apache
-- Maintainer:  Bryan O'Sullivan <bos@serpentine.com>
-- Stability:   experimental
-- Portability: portable
--
-- Storage and retrieval of data with automatic conflict resolution.
--
-- The 'put' and 'putMany' functions will attempt to perform automatic
-- conflict resolution a large number of times.  If they give up due
-- to apparently being stuck in a loop, they will throw a
-- 'ResolutionFailure' exception.

module Network.Riak.Resolvable.Internal
    (
      Resolvable(..)
    , ResolvableMonoid(..)
    , ResolutionFailure(..)
    , get
    , getMany
    , modify
    , modify_
    , put
    , put_
    , putMany
    , putMany_
    ) where

import Control.Applicative ((<$>))
import Control.Arrow (first)
import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Data.Aeson.Types (FromJSON, ToJSON)
import Data.Data (Data)
import Data.Either (partitionEithers)
import Data.Function (on)
import Data.List (foldl', sortBy)
import Data.Maybe (isJust)
import Data.Monoid (Monoid(mappend))
import Data.Typeable (Typeable)
import Network.Riak.Debug (debugValues)
import Network.Riak.Types.Internal hiding (MessageTag(..))

-- | Automated conflict resolution failed.
data ResolutionFailure = RetriesExceeded
    -- ^ Too many attempts were made to resolve a conflict, with each
    -- attempt resulting in another conflict.
    --
    -- The number of retries that the library will attempt is high
    -- (64). This makes it extremely unlikely that this exception will
    -- be thrown during normal application operation.  Instead, this
    -- exception is most likely to be thrown as a result of a bug in
    -- your application code, for example if your 'resolve' function
    -- is misbehaving.
                         deriving (Eq, Show, Typeable)

instance Exception ResolutionFailure

-- | A type that can automatically resolve a vector clock conflict
-- between two or more versions of a value.
--
-- Instances must be symmetric in their behaviour, such that the
-- following law is obeyed:
--
-- > resolve a b == resolve b a
--
-- Otherwise, there are no restrictions on the behaviour of 'resolve'.
-- The result may be @a@, @b@, a value derived from @a@ and @b@, or
-- something else.
--
-- If several conflicting siblings are found, 'resolve' will be
-- applied over all of them using a fold, to yield a single
-- \"winner\".
class (Show a) => Resolvable a where
    -- | Resolve a conflict between two values.
    resolve :: a -> a -> a

-- | A newtype wrapper that uses the 'mappend' method of a type's
-- 'Monoid' instance to perform vector clock conflict resolution.
newtype ResolvableMonoid a = RM { unRM :: a }
    deriving (Eq, Ord, Read, Show, Typeable, Data, Monoid, FromJSON, ToJSON)

instance (Eq a, Show a, Monoid a) => Resolvable (ResolvableMonoid a) where
    resolve = mappend
    {-# INLINE resolve #-}

instance (Resolvable a) => Resolvable (Maybe a) where
    resolve (Just a)   (Just b) = Just (resolve a b)
    resolve a@(Just _) _        = a
    resolve _          b        = b
    {-# INLINE resolve #-}

type Get a = Connection -> Bucket -> Key -> R -> IO (Maybe ([a], VClock))

get :: (Resolvable a) => Get a
    -> (Connection -> Bucket -> Key -> R -> IO (Maybe (a, VClock)))
get doGet conn bucket k r =
    fmap (first resolveMany) `fmap` doGet conn bucket k r
{-# INLINE get #-}

getMany :: (Resolvable a) =>
           (Connection -> Bucket -> [Key] -> R -> IO [Maybe ([a], VClock)])
        -> Connection -> Bucket -> [Key] -> R -> IO [Maybe (a, VClock)]
getMany doGet conn b ks r =
    map (fmap (first resolveMany)) `fmap` doGet conn b ks r
{-# INLINE getMany #-}

-- If Riak receives a put request with no vclock, and the given
-- bucket+key already exists, it will treat the missing vclock as
-- stale, ignore the put request, and send back whatever values it
-- currently knows about.  The same problem will arise if we send a
-- vclock that really is stale, but that's much less likely to occur.
-- We handle the missing-vclock case in the single-body-response case
-- of both put and putMany below, but we do not (can not?) handle the
-- stale-vclock case.

type Put a = Connection -> Bucket -> PutInfo -> a -> W -> DW
           -> IO (PutResult [a])

hasVClock :: PutInfo -> Bool
hasVClock Nothing = False
hasVClock (Just (_, mv)) = isJust mv
{-# INLINE hasVClock #-}

changeVClock :: Maybe VClock -> PutInfo -> PutInfo
changeVClock c = fmap (\(l,_) -> (l, c))
{-# INLINE changeVClock #-}

put :: (Resolvable a) => Put a
    -> Connection -> Bucket -> PutInfo -> a -> W -> DW
    -> IO (PutResult a)
put doPut conn bucket p val0 w dw = do
  let go !i val p'
         | i == maxRetries = throwIO RetriesExceeded
         | otherwise       = do
           pr <- doPut conn bucket p' val w dw
           case result pr of
             [x] | i > 0 || hasVClock p' -> return $ pr { result = x }
             xs@(_:_) -> do debugValues "put" "conflict" xs
                            go (i+1) (resolveMany' val xs) $ changeVClock (vclock pr) p'
             []    -> unexError "Network.Riak.Resolvable" "put"
                      "received empty response from server"
  go (0::Int) val0 p
{-# INLINE put #-}

-- | The maximum number of times to retry conflict resolution.
maxRetries :: Int
maxRetries = 64
{-# INLINE maxRetries #-}

put_ :: (Resolvable a) =>
        (Connection -> Bucket -> PutInfo -> a -> W -> DW
                    -> IO (PutResult [a]))
     -> Connection -> Bucket -> PutInfo -> a -> W -> DW
     -> IO ()
put_ doPut conn bucket p val0 w dw =
    put doPut conn bucket p val0 w dw >> return ()
{-# INLINE put_ #-}

modify :: (Resolvable a) => Get a -> Put a
       -> Connection -> Bucket -> Key -> R -> W -> DW -> (Maybe a -> IO (a,b))
       -> IO (a,b)
modify doGet doPut conn bucket k r w dw act = do
  a0 <- get doGet conn bucket k r
  (a,b) <- act (fst <$> a0)
  pr <- put doPut conn bucket (Just (k, (snd <$> a0))) a w dw
  return (result pr,b)
{-# INLINE modify #-}

modify_ :: (Resolvable a) => Get a -> Put a
        -> Connection -> Bucket -> Key -> R -> W -> DW -> (Maybe a -> IO a)
        -> IO a
modify_ doGet doPut conn bucket k r w dw act = do
  a0 <- get doGet conn bucket k r
  a <- act (fst <$> a0)
  result <$> put doPut conn bucket (Just (k, (snd <$> a0))) a w dw
{-# INLINE modify_ #-}

putMany :: (Resolvable a) =>
           (Connection -> Bucket -> [(PutInfo, a)] -> W -> DW
                       -> IO [PutResult [a]])
        -> Connection -> Bucket -> [(PutInfo, a)] -> W -> DW
        -> IO [PutResult a]
putMany doPut conn bucket puts0 w dw = go (0::Int) [] . zip [(0::Int)..] $ puts0
 where
  go _ acc [] = return . map snd . sortBy (compare `on` fst) $ acc
  go !i acc puts
      | i == maxRetries = throwIO RetriesExceeded
      | otherwise = do
    rs <- doPut conn bucket (map snd puts) w dw
    let (conflicts, ok) = partitionEithers $ zipWith mush puts rs
    unless (null conflicts) $
      debugValues "putMany" "conflicts" conflicts
    go (i+1) (ok++acc) conflicts
  mush (i,(p,c)) r =
      case result r of
        [x] | i > 0 || hasVClock p -> Right (i, r { result = x })
        xs@(_:_) -> Left (i, (changeVClock (vclock r) p, resolveMany' c xs))
        []    -> unexError "Network.Riak.Resolvable" "put"
                 "received empty response from server"
{-# INLINE putMany #-}

putMany_ :: (Resolvable a) =>
            (Connection -> Bucket -> [(PutInfo, a)] -> W -> DW
                        -> IO [PutResult [a]])
         -> Connection -> Bucket -> [(PutInfo, a)] -> W -> DW -> IO ()
putMany_ doPut conn bucket puts0 w dw =
    putMany doPut conn bucket puts0 w dw >> return ()
{-# INLINE putMany_ #-}

resolveMany' :: (Resolvable a) => a -> [a] -> a
resolveMany' = foldl' resolve
{-# INLINE resolveMany' #-}

resolveMany :: (Resolvable a) => [a] -> a
resolveMany (a:as) = resolveMany' a as
resolveMany _      = error "resolveMany: empty list"
{-# INLINE resolveMany #-}
