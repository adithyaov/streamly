{-# LANGUAGE BangPatterns              #-}
{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ConstraintKinds           #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE MultiParamTypeClasses     #-}
{-# LANGUAGE PatternSynonyms           #-}
{-# LANGUAGE RecordWildCards           #-}
{-# LANGUAGE ScopedTypeVariables       #-}
{-# LANGUAGE ViewPatterns              #-}
{-# LANGUAGE RankNTypes                #-}

#include "inline.hs"

-- |
-- Module      : Streamly.Streams.StreamD
-- Copyright   : (c) 2018 Harendra Kumar
-- Copyright   : (c) Roman Leshchinskiy 2008-2010
--
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC
--
-- Direct style re-implementation of CPS style stream in StreamK module.  The
-- symbol or suffix 'D' in this module denotes the "Direct" style.  GHC is able
-- to INLINE and fuse direct style better, providing better performance than
-- CPS implementation.
--
-- @
-- import qualified Streamly.Streams.StreamD as D
-- @

-- Some of the functions in this file have been adapted from the vector
-- library,  https://hackage.haskell.org/package/vector.

module Streamly.Streams.StreamD
    (
    -- * The stream type
      Step (..)
    , Stream (..)

    -- * Construction
    , nil
    , cons

    -- * Deconstruction
    , uncons

    -- * Generation
    -- ** Unfolds
    , unfoldr
    , unfoldrM

    -- ** Specialized Generation
    -- | Generate a monadic stream from a seed.
    , repeat
    , replicate
    , replicateM
    , fromIndices
    , fromIndicesM
    , generate
    , generateM

    -- ** Enumerations
    , enumerateFromStepIntegral
    , enumerateFromIntegral
    , enumerateFromThenIntegral
    , enumerateFromToIntegral
    , enumerateFromThenToIntegral

    , enumerateFromStepNum
    , numFrom
    , numFromThen
    , enumerateFromToFractional
    , enumerateFromThenToFractional

    -- ** Conversions
    -- | Transform an input structure into a stream.
    -- | Direct style stream does not support @fromFoldable@.
    , yield
    , yieldM
    , fromList
    , fromListM
    , fromArray
    , fromStreamK
    , fromStreamD

    -- * Elimination
    -- ** General Folds
    , foldr
    , foldrM
    , foldrMx
    , foldr1
    , foldl'
    , foldlM'
    , foldlS
    , foldlT
    , foldx'
    , foldxM'
    , parselMx'
    , foldrT
    , reverse

    -- ** Specialized Folds
    , tap
    , runStream
    , null
    , head
    , tail
    , last
    , elem
    , notElem
    , all
    , any
    , maximum
    , maximumBy
    , minimum
    , minimumBy
    , findIndices
    , lookup
    , findM
    , find
    , (!!)

    -- ** Flattening nested streams
    , concatMapM
    , concatMap
    , concatArray
    , groupsOf
    , arrayGroupsOf
    , splitOn
    , grouped
    , chained
    , linesWhen
    , wordsWhen
    , foldBufferWith

    -- ** Substreams
    , isPrefixOf
    , isSubsequenceOf
    , stripPrefix

    -- ** Map and Fold
    , mapM_

    -- ** Conversions
    -- | Transform a stream into another type.
    , toList
    , toRevList
    -- , toArray
    , toStreamK
    , toStreamD

    -- * Transformation
    -- ** By folding (scans)
    , scanlM'
    , scanl'
    , scanlM
    , scanl
    , scanl1M'
    , scanl1'
    , scanl1M
    , scanl1

    , prescanl'
    , prescanlM'
    , postscanl
    , postscanlM
    , postscanl'
    , postscanlM'

    , postscanxM'
    , postscanx'
    , scanxM'
    , scanx'

    -- * Filtering
    , filter
    , filterM
    , uniq
    , take
    , takeWhile
    , takeWhileM
    , drop
    , dropWhile
    , dropWhileM

    -- * Mapping
    , map
    , mapM
    , sequence

    -- * Inserting
    , insertBy

    -- * Deleting
    , deleteBy

    -- ** Map and Filter
    , mapMaybe
    , mapMaybeM

    -- * Zipping
    , indexed
    , indexedR
    , zipWith
    , zipWithM

    -- * Comparisions
    , eqBy
    , cmpBy

    -- * Merging
    , mergeBy
    , mergeByM

    -- * Transformation comprehensions
    , the
    )
where

import Control.Monad.IO.Class (MonadIO)
import Control.Monad.Trans (MonadTrans(lift))
import Control.Monad.Trans.State.Lazy (StateT(..), put)
import Data.Bits (finiteBitSize)
import Data.Maybe (fromJust, isJust)
import Foreign.ForeignPtr (ForeignPtr, touchForeignPtr)
import Foreign.ForeignPtr.Unsafe (unsafeForeignPtrToPtr)
import Foreign.Ptr (Ptr, plusPtr, minusPtr)
import Foreign.Storable (Storable(..))
import GHC.Types (SPEC(..))
import Prelude
       hiding (map, mapM, mapM_, repeat, foldr, last, take, filter,
               takeWhile, drop, dropWhile, all, any, maximum, minimum, elem,
               notElem, null, head, tail, zipWith, lookup, foldr1, sequence,
               (!!), scanl, scanl1, concatMap, replicate, enumFromTo, concat,
               reverse)
import System.IO.Unsafe (unsafeDupablePerformIO)

import Streamly.Array.Types
       (Array(..), Array, unsafeDangerousPerformIO, unsafeIndex,
        unsafeAppend, unsafeNew)
import Streamly.Fold.Types (Fold(..))
import Streamly.SVar (MonadAsync, defState, adaptState, State)
import Streamly.Sink.Types (Sink(..))

import Streamly.Streams.StreamD.Type
import Streamly.Parse.Types (Status(..), Parse(..))
import qualified Streamly.Streams.StreamK as K



------------------------------------------------------------------------------
-- Construction
------------------------------------------------------------------------------

-- | An empty 'Stream'.
{-# INLINE_NORMAL nil #-}
nil :: Monad m => Stream m a
nil = Stream (\_ _ -> return Stop) ()

{-# INLINE_NORMAL consM #-}
consM :: Monad m => m a -> Stream m a -> Stream m a
consM m (Stream step state) = Stream step1 Nothing
    where
    {-# INLINE_LATE step1 #-}
    step1 _ Nothing   = m >>= \x -> return $ Yield x (Just state)
    step1 gst (Just st) = do
        r <- step gst st
        return $
          case r of
            Yield a s -> Yield a (Just s)
            Skip  s   -> Skip (Just s)
            Stop      -> Stop

-- XXX implement in terms of consM?
-- cons x = consM (return x)
--
-- | Can fuse but has O(n^2) complexity.
{-# INLINE_NORMAL cons #-}
cons :: Monad m => a -> Stream m a -> Stream m a
cons x (Stream step state) = Stream step1 Nothing
    where
    {-# INLINE_LATE step1 #-}
    step1 _ Nothing   = return $ Yield x (Just state)
    step1 gst (Just st) = do
        r <- step gst st
        return $
          case r of
            Yield a s -> Yield a (Just s)
            Skip  s   -> Skip (Just s)
            Stop      -> Stop

-------------------------------------------------------------------------------
-- Deconstruction
-------------------------------------------------------------------------------

-- Does not fuse, has the same performance as the StreamK version.
{-# INLINE_NORMAL uncons #-}
uncons :: Monad m => Stream m a -> m (Maybe (a, Stream m a))
uncons (UnStream step state) = go state
  where
    go st = do
        r <- step defState st
        case r of
            Yield x s -> return $ Just (x, Stream step s)
            Skip  s   -> go s
            Stop      -> return Nothing

------------------------------------------------------------------------------
-- Generation by unfold
------------------------------------------------------------------------------

{-# INLINE_NORMAL unfoldrM #-}
unfoldrM :: Monad m => (s -> m (Maybe (a, s))) -> s -> Stream m a
unfoldrM next state = Stream step state
  where
    {-# INLINE_LATE step #-}
    step _ st = do
        r <- next st
        return $ case r of
            Just (x, s) -> Yield x s
            Nothing     -> Stop

{-# INLINE_LATE unfoldr #-}
unfoldr :: Monad m => (s -> Maybe (a, s)) -> s -> Stream m a
unfoldr f = unfoldrM (return . f)

------------------------------------------------------------------------------
-- Specialized Generation
------------------------------------------------------------------------------

repeat :: Monad m => a -> Stream m a
repeat x = Stream (\_ _ -> return $ Yield x ()) ()

{-# INLINE_NORMAL replicateM #-}
replicateM :: Monad m => Int -> m a -> Stream m a
replicateM n p = Stream step n
  where
    {-# INLINE_LATE step #-}
    step _ i | i <= 0    = return Stop
             | otherwise = do
                x <- p
                return $ Yield x (i - 1)

{-# INLINE_NORMAL replicate #-}
replicate :: Monad m => Int -> a -> Stream m a
replicate n x = replicateM n (return x)

-- This would not work properly for floats, therefore we put an Integral
-- constraint.
-- | Can be used to enumerate unbounded integrals. This does not check for
-- overflow or underflow for bounded integrals.
{-# INLINE_NORMAL enumerateFromStepIntegral #-}
enumerateFromStepIntegral :: (Integral a, Monad m) => a -> a -> Stream m a
enumerateFromStepIntegral from stride =
    from `seq` stride `seq` Stream step from
    where
        {-# INLINE_LATE step #-}
        step _ !x = return $ Yield x $! (x + stride)

-- We are assuming that "to" is constrained by the type to be within
-- max/min bounds.
{-# INLINE enumerateFromToIntegral #-}
enumerateFromToIntegral :: (Monad m, Integral a) => a -> a -> Stream m a
enumerateFromToIntegral from to =
    takeWhile (<= to) $ enumerateFromStepIntegral from 1

{-# INLINE enumerateFromIntegral #-}
enumerateFromIntegral :: (Monad m, Integral a, Bounded a) => a -> Stream m a
enumerateFromIntegral from = enumerateFromToIntegral from maxBound

data EnumState a = EnumInit | EnumYield a a a | EnumStop

{-# INLINE_NORMAL enumerateFromThenToIntegralUp #-}
enumerateFromThenToIntegralUp
    :: (Monad m, Integral a)
    => a -> a -> a -> Stream m a
enumerateFromThenToIntegralUp from next to = Stream step EnumInit
    where
    {-# INLINE_LATE step #-}
    step _ EnumInit =
        return $
            if to < next
            then if to < from
                 then Stop
                 else Yield from EnumStop
            else -- from <= next <= to
                let stride = next - from
                in Skip $ EnumYield from stride (to - stride)

    step _ (EnumYield x stride toMinus) =
        return $
            if x > toMinus
            then Yield x EnumStop
            else Yield x $ EnumYield (x + stride) stride toMinus

    step _ EnumStop = return Stop

{-# INLINE_NORMAL enumerateFromThenToIntegralDn #-}
enumerateFromThenToIntegralDn
    :: (Monad m, Integral a)
    => a -> a -> a -> Stream m a
enumerateFromThenToIntegralDn from next to = Stream step EnumInit
    where
    {-# INLINE_LATE step #-}
    step _ EnumInit =
        return $ if to > next
            then if to > from
                 then Stop
                 else Yield from EnumStop
            else -- from >= next >= to
                let stride = next - from
                in Skip $ EnumYield from stride (to - stride)

    step _ (EnumYield x stride toMinus) =
        return $
            if x < toMinus
            then Yield x EnumStop
            else Yield x $ EnumYield (x + stride) stride toMinus

    step _ EnumStop = return Stop

{-# INLINE_NORMAL enumerateFromThenToIntegral #-}
enumerateFromThenToIntegral
    :: (Monad m, Integral a)
    => a -> a -> a -> Stream m a
enumerateFromThenToIntegral from next to
    | next >= from = enumerateFromThenToIntegralUp from next to
    | otherwise    = enumerateFromThenToIntegralDn from next to

{-# INLINE_NORMAL enumerateFromThenIntegral #-}
enumerateFromThenIntegral
    :: (Monad m, Integral a, Bounded a)
    => a -> a -> Stream m a
enumerateFromThenIntegral from next =
    if next > from
    then enumerateFromThenToIntegralUp from next maxBound
    else enumerateFromThenToIntegralDn from next minBound

-- For floating point numbers if the increment is less than the precision then
-- it just gets lost. Therefore we cannot always increment it correctly by just
-- repeated addition.
-- 9007199254740992 + 1 + 1 :: Double => 9.007199254740992e15
-- 9007199254740992 + 2     :: Double => 9.007199254740994e15

-- Instead we accumulate the increment counter and compute the increment
-- everytime before adding it to the starting number.
--
-- This works for Integrals as well as floating point numbers, but
-- enumerateFromStepIntegral is faster for integrals.
{-# INLINE_NORMAL enumerateFromStepNum #-}
enumerateFromStepNum :: (Monad m, Num a) => a -> a -> Stream m a
enumerateFromStepNum from stride = Stream step 0
    where
    {-# INLINE_LATE step #-}
    step _ !i = return $ (Yield $! (from + i * stride)) $! (i + 1)

{-# INLINE_NORMAL numFrom #-}
numFrom :: (Monad m, Num a) => a -> Stream m a
numFrom from = enumerateFromStepNum from 1

{-# INLINE_NORMAL numFromThen #-}
numFromThen :: (Monad m, Num a) => a -> a -> Stream m a
numFromThen from next = enumerateFromStepNum from (next - from)

-- We cannot write a general function for Num.  The only way to write code
-- portable between the two is to use a 'Real' constraint and convert between
-- Fractional and Integral using fromRational which is horribly slow.
{-# INLINE_NORMAL enumerateFromToFractional #-}
enumerateFromToFractional
    :: (Monad m, Fractional a, Ord a)
    => a -> a -> Stream m a
enumerateFromToFractional from to =
    takeWhile (<= to + 1 / 2) $ enumerateFromStepNum from 1

{-# INLINE_NORMAL enumerateFromThenToFractional #-}
enumerateFromThenToFractional
    :: (Monad m, Fractional a, Ord a)
    => a -> a -> a -> Stream m a
enumerateFromThenToFractional from next to =
    takeWhile predicate $ numFromThen from next
    where
    mid = (next - from) / 2
    predicate | next >= from  = (<= to + mid)
              | otherwise     = (>= to + mid)

-------------------------------------------------------------------------------
-- Generation by Conversion
-------------------------------------------------------------------------------

-- | Create a singleton 'Stream' from a pure value.
{-# INLINE_NORMAL yield #-}
yield :: Monad m => a -> Stream m a
yield x = Stream (\_ s -> return $ step undefined s) True
  where
    {-# INLINE_LATE step #-}
    step _ True  = Yield x False
    step _ False = Stop

-- | Create a singleton 'Stream' from a monadic action.
{-# INLINE_NORMAL yieldM #-}
yieldM :: Monad m => m a -> Stream m a
yieldM m = Stream step True
  where
    {-# INLINE_LATE step #-}
    step _ True  = m >>= \x -> return $ Yield x False
    step _ False = return Stop

{-# INLINE_NORMAL fromIndicesM #-}
fromIndicesM :: Monad m => (Int -> m a) -> Stream m a
fromIndicesM gen = Stream step 0
  where
    {-# INLINE_LATE step #-}
    step _ i = do
       x <- gen i
       return $ Yield x (i + 1)

{-# INLINE fromIndices #-}
fromIndices :: Monad m => (Int -> a) -> Stream m a
fromIndices gen = fromIndicesM (return . gen)

{-# INLINE_NORMAL generateM #-}
generateM :: Monad m => Int -> (Int -> m a) -> Stream m a
generateM n gen = n `seq` Stream step 0
  where
    {-# INLINE_LATE step #-}
    step _ i | i < n     = do
                           x <- gen i
                           return $ Yield x (i + 1)
             | otherwise = return Stop

{-# INLINE generate #-}
generate :: Monad m => Int -> (Int -> a) -> Stream m a
generate n gen = generateM n (return . gen)

-- XXX we need the MonadAsync constraint because of a rewrite rule.
-- | Convert a list of monadic actions to a 'Stream'
{-# INLINE_LATE fromListM #-}
fromListM :: MonadAsync m => [m a] -> Stream m a
fromListM = Stream step
  where
    {-# INLINE_LATE step #-}
    step _ (m:ms) = m >>= \x -> return $ Yield x ms
    step _ []     = return Stop

-- | Convert a list of pure values to a 'Stream'
{-# INLINE_LATE fromList #-}
fromList :: Monad m => [a] -> Stream m a
fromList = Stream step
  where
    {-# INLINE_LATE step #-}
    step _ (x:xs) = return $ Yield x xs
    step _ []     = return Stop

{-# INLINE fromArray #-}
fromArray :: forall m a. (Monad m, Storable a) => Array a -> Stream m a
fromArray Array{..} =
    let p = unsafeForeignPtrToPtr aStart
    in Stream step p

    where

    {-# INLINE_LATE step #-}
    step _ p | p == aEnd = return Stop
    step _ p = do
        let !x = unsafeDangerousPerformIO $ do
                    r <- peek p
                    -- XXX should we keep aStart in the state?
                    touchForeignPtr aStart
                    return r
        return $ Yield x (p `plusPtr` (sizeOf (undefined :: a)))

{-# INLINE_LATE fromStreamK #-}
fromStreamK :: Monad m => K.Stream m a -> Stream m a
fromStreamK = Stream step
    where
    step gst m1 =
        let stop       = return Stop
            single a   = return $ Yield a K.nil
            yieldk a r = return $ Yield a r
         in K.foldStreamShared gst yieldk single stop m1

{-# INLINE toStreamD #-}
toStreamD :: (K.IsStream t, Monad m) => t m a -> Stream m a
toStreamD = fromStreamK . K.toStream

------------------------------------------------------------------------------
-- Elimination by Folds
------------------------------------------------------------------------------

{-# INLINE_NORMAL foldr1 #-}
foldr1 :: Monad m => (a -> a -> a) -> Stream m a -> m (Maybe a)
foldr1 f m = do
     r <- uncons m
     case r of
         Nothing   -> return Nothing
         Just (h, t) -> fmap Just (foldr f h t)

-- XXX run begin action only if the stream is not empty.
{-# INLINE_NORMAL foldxM' #-}
foldxM' :: Monad m => (x -> a -> m x) -> m x -> (x -> m b) -> Stream m a -> m b
foldxM' fstep begin done (Stream step state) =
    begin >>= \x -> go SPEC x state
  where
    -- XXX !acc?
    go !_ acc st = acc `seq` do
        r <- step defState st
        case r of
            Yield x s -> do
                acc' <- fstep acc x
                go SPEC acc' s
            Skip s -> go SPEC acc s
            Stop   -> done acc

{-# INLINE foldx' #-}
foldx' :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream m a -> m b
foldx' fstep begin done m =
    foldxM' (\b a -> return (fstep b a)) (return begin) (return . done) m

-- XXX implement in terms of foldxM'
{-# INLINE_NORMAL foldlM' #-}
foldlM' :: Monad m => (b -> a -> m b) -> b -> Stream m a -> m b
foldlM' fstep begin (Stream step state) = go SPEC begin state
  where
    go !_ acc st = acc `seq` do
        r <- step defState st
        case r of
            Yield x s -> do
                acc' <- fstep acc x
                go SPEC acc' s
            Skip s -> go SPEC acc s
            Stop   -> return acc

-- Note, this is going to have horrible performance, because of the nature of
-- the stream type. Its only for reference, it is likely be practically
-- unusable.
{-# INLINE_NORMAL foldlS #-}
foldlS :: Monad m
    => (Stream m b -> a -> Stream m b) -> Stream m b -> Stream m a -> Stream m b
foldlS fstep begin (Stream step state) = Stream step' (Left (state, begin))
  where
    step' gst (Left (st, acc)) = do
        r <- step (adaptState gst) st
        return $ case r of
            Yield x s -> Skip (Left (s, fstep acc x))
            Skip s -> Skip (Left (s, acc))
            Stop   -> Skip (Right acc)

    step' gst (Right (Stream stp stt)) = do
        r <- stp (adaptState gst) stt
        return $ case r of
            Yield x s -> Yield x (Right (Stream stp s))
            Skip s -> Skip (Right (Stream stp s))
            Stop   -> Stop

{-# INLINE toRevList #-}
toRevList :: Monad m => Stream m a -> m [a]
toRevList = foldl' (flip (:)) []

{-# INLINE_NORMAL reverse #-}
reverse :: Monad m => Stream m a -> Stream m a
-- The foldl based implementation is unusable because of the horrible
-- performance of cons. So we just convert it to a list first and then stream
-- from the list.
-- reverse = foldlS (flip cons) nil
reverse m = Stream step Nothing
    where
        step _ Nothing = do
            xs <- toRevList m
            return $ Skip (Just xs)
        step _ (Just (x:xs)) = return $ Yield x (Just xs)
        step _ (Just []) = return Stop

{-# INLINE_NORMAL foldlT #-}
foldlT :: (Monad m, Monad (s m), MonadTrans s)
    => (s m b -> a -> s m b) -> s m b -> Stream m a -> s m b
foldlT fstep begin (Stream step state) = go SPEC begin state
  where
    go !_ acc st = do
        r <- lift $ step defState st
        case r of
            Yield x s -> go SPEC (fstep acc x) s
            Skip s -> go SPEC acc s
            Stop   -> acc

{-# INLINE foldl' #-}
foldl' :: Monad m => (b -> a -> b) -> b -> Stream m a -> m b
foldl' fstep = foldlM' (\b a -> return (fstep b a))

-- | A Success result stops the recursion.
{-# INLINE_NORMAL parselMx' #-}
parselMx' :: Monad m => (x -> a -> m (Status x)) -> m (Status x) -> (x -> m b) -> Stream m a -> m b
parselMx' fstep begin done (Stream step state) =
    begin >>= \x ->
        -- XXX can we have begin to always be assumed as "Partial"
        -- and make it type "m x" instead of "m (Status x)"
        case x of
            Success a -> done a
            Partial a -> go SPEC a state
  where
    -- XXX !acc?
    go !_ acc st = do
        -- XXX Can we put that branch here instead?
        r <- step defState st
        case r of
            Yield x s -> do
                acc' <- fstep acc x
                -- XXX when we pass acc wrapped with Done/More, then composed any/all
                -- performance is 6x better. This "done" branch here vs putting the
                -- done branch in the next iteration of the loop makes the
                -- difference.
                case acc' of
                    Partial a -> go SPEC a s
                    Success a -> done a
            Skip s -> go SPEC acc s
            Stop   -> done acc

------------------------------------------------------------------------------
-- Specialized Folds
------------------------------------------------------------------------------

-- | Run a streaming composition, discard the results.
{-# INLINE_LATE runStream #-}
runStream :: Monad m => Stream m a -> m ()
runStream m = foldrM (\x xs -> x `seq` xs) (return ()) m

{-# INLINE_NORMAL null #-}
null :: Monad m => Stream m a -> m Bool
null m = foldrM (\_ _ -> return False) (return True) m

-- XXX SPEC?
{-# INLINE_NORMAL head #-}
head :: Monad m => Stream m a -> m (Maybe a)
head m = foldrM (\x _ -> return (Just x)) (return Nothing) m

-- Does not fuse, has the same performance as the StreamK version.
{-# INLINE_NORMAL tail #-}
tail :: Monad m => Stream m a -> m (Maybe (Stream m a))
tail (UnStream step state) = go state
  where
    go st = do
        r <- step defState st
        case r of
            Yield _ s -> return (Just $ Stream step s)
            Skip  s   -> go s
            Stop      -> return Nothing

-- XXX will it fuse? need custom impl?
{-# INLINE_NORMAL last #-}
last :: Monad m => Stream m a -> m (Maybe a)
last = foldl' (\_ y -> Just y) Nothing

{-# INLINE_NORMAL elem #-}
elem :: (Monad m, Eq a) => a -> Stream m a -> m Bool
elem e m = foldrM (\x xs -> if x == e then return True else xs) (return False) m

{-# INLINE_NORMAL notElem #-}
notElem :: (Monad m, Eq a) => a -> Stream m a -> m Bool
notElem e s = fmap not (elem e s)

{-# INLINE_NORMAL all #-}
all :: Monad m => (a -> Bool) -> Stream m a -> m Bool
all p m = foldrM (\x xs -> if p x then xs else return False) (return True) m

{-# INLINE_NORMAL any #-}
any :: Monad m => (a -> Bool) -> Stream m a -> m Bool
any p m = foldrM (\x xs -> if p x then return True else xs) (return False) m

{-# INLINE_NORMAL maximum #-}
maximum :: (Monad m, Ord a) => Stream m a -> m (Maybe a)
maximum (Stream step state) = go Nothing state
  where
    go Nothing st = do
        r <- step defState st
        case r of
            Yield x s -> go (Just x) s
            Skip  s   -> go Nothing s
            Stop      -> return Nothing
    go (Just acc) st = do
        r <- step defState st
        case r of
            Yield x s
              | acc <= x  -> go (Just x) s
              | otherwise -> go (Just acc) s
            Skip s -> go (Just acc) s
            Stop   -> return (Just acc)

{-# INLINE_NORMAL maximumBy #-}
maximumBy :: Monad m => (a -> a -> Ordering) -> Stream m a -> m (Maybe a)
maximumBy cmp (Stream step state) = go Nothing state
  where
    go Nothing st = do
        r <- step defState st
        case r of
            Yield x s -> go (Just x) s
            Skip  s   -> go Nothing s
            Stop      -> return Nothing
    go (Just acc) st = do
        r <- step defState st
        case r of
            Yield x s -> case cmp acc x of
                GT -> go (Just acc) s
                _  -> go (Just x) s
            Skip s -> go (Just acc) s
            Stop   -> return (Just acc)

{-# INLINE_NORMAL minimum #-}
minimum :: (Monad m, Ord a) => Stream m a -> m (Maybe a)
minimum (Stream step state) = go Nothing state
  where
    go Nothing st = do
        r <- step defState st
        case r of
            Yield x s -> go (Just x) s
            Skip  s   -> go Nothing s
            Stop      -> return Nothing
    go (Just acc) st = do
        r <- step defState st
        case r of
            Yield x s
              | acc <= x  -> go (Just acc) s
              | otherwise -> go (Just x) s
            Skip s -> go (Just acc) s
            Stop   -> return (Just acc)

{-# INLINE_NORMAL minimumBy #-}
minimumBy :: Monad m => (a -> a -> Ordering) -> Stream m a -> m (Maybe a)
minimumBy cmp (Stream step state) = go Nothing state
  where
    go Nothing st = do
        r <- step defState st
        case r of
            Yield x s -> go (Just x) s
            Skip  s   -> go Nothing s
            Stop      -> return Nothing
    go (Just acc) st = do
        r <- step defState st
        case r of
            Yield x s -> case cmp acc x of
                GT -> go (Just x) s
                _  -> go (Just acc) s
            Skip s -> go (Just acc) s
            Stop   -> return (Just acc)

{-# INLINE_NORMAL (!!) #-}
(!!) :: (Monad m) => Stream m a -> Int -> m (Maybe a)
(Stream step state) !! i = go i state
  where
    go n st = do
        r <- step defState st
        case r of
            Yield x s | n < 0 -> return Nothing
                      | n == 0 -> return $ Just x
                      | otherwise -> go (n - 1) s
            Skip s -> go n s
            Stop   -> return Nothing

{-# INLINE_NORMAL lookup #-}
lookup :: (Monad m, Eq a) => a -> Stream m (a, b) -> m (Maybe b)
lookup e m = foldrM (\(a, b) xs -> if e == a then return (Just b) else xs)
                   (return Nothing) m

{-# INLINE_NORMAL findM #-}
findM :: Monad m => (a -> m Bool) -> Stream m a -> m (Maybe a)
findM p m = foldrM (\x xs -> p x >>= \r -> if r then return (Just x) else xs)
                   (return Nothing) m

{-# INLINE find #-}
find :: Monad m => (a -> Bool) -> Stream m a -> m (Maybe a)
find p = findM (return . p)

{-# INLINE_NORMAL findIndices #-}
findIndices :: Monad m => (a -> Bool) -> Stream m a -> Stream m Int
findIndices p (Stream step state) = Stream step' (state, 0)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, i) = do
      r <- step (adaptState gst) st
      return $ case r of
          Yield x s -> if p x then Yield i (s, i+1) else Skip (s, i+1)
          Skip s -> Skip (s, i+1)
          Stop   -> Stop

------------------------------------------------------------------------------
-- concatMap
------------------------------------------------------------------------------

{-# INLINE_NORMAL concatMapM #-}
concatMapM :: Monad m => (a -> m (Stream m b)) -> Stream m a -> Stream m b
concatMapM f (Stream step state) = Stream step' (Left state)
  where
    {-# INLINE_LATE step' #-}
    step' gst (Left st) = do
        r <- step (adaptState gst) st
        case r of
            Yield a s -> do
                b_stream <- f a
                return $ Skip (Right (b_stream, s))
            Skip s -> return $ Skip (Left s)
            Stop -> return Stop

    -- XXX concatArray is 5x faster than "concatMap fromArray". if somehow we
    -- can get inner_step to inline and fuse here we can perhaps get the same
    -- performance using "concatMap fromArray".
    --
    -- XXX using the pattern synonym "Stream" causes a major performance issue
    -- here even if the synonym does not include an adaptState call. Need to
    -- find out why. Is that something to be fixed in GHC?
    step' gst (Right (UnStream inner_step inner_st, st)) = do
        r <- inner_step (adaptState gst) inner_st
        case r of
            Yield b inner_s ->
                return $ Yield b (Right (Stream inner_step inner_s, st))
            Skip inner_s ->
                return $ Skip (Right (Stream inner_step inner_s, st))
            Stop -> return $ Skip (Left st)

-- XXX concatMap does not seem to have the best possible performance so we have
-- a custom way to concat arrays.
data CAState s a = CAParent s | CANested s (ForeignPtr a) (Ptr a) (Ptr a)

{-# INLINE_NORMAL concatArray #-}
concatArray :: forall m a. (Monad m, Storable a)
    => Stream m (Array a) -> Stream m a
concatArray (Stream step state) = Stream step' (CAParent state)

    where

    {-# INLINE_LATE step' #-}
    step' gst (CAParent st) = do
        r <- step (adaptState gst) st
        return $ case r of
            Yield Array{..} s ->
                let p = unsafeForeignPtrToPtr aStart
                in Skip (CANested s aStart p aEnd)
            Skip s -> Skip (CAParent s)
            Stop -> Stop

    step' _ (CANested st _ p end) | p == end =
        return $ Skip $ CAParent st

    step' _ (CANested st startf p end) = do
        let !x = unsafeDangerousPerformIO $ do
                    r <- peek p
                    touchForeignPtr startf
                    return r
        return $ Yield x (CANested st startf
                            (p `plusPtr` (sizeOf (undefined :: a))) end)

{-# INLINE concatMap #-}
concatMap :: Monad m => (a -> Stream m b) -> Stream m a -> Stream m b
concatMap f = concatMapM (return . f)

------------------------------------------------------------------------------
-- Grouping/Splitting
------------------------------------------------------------------------------

-- XXX we need an INLINE_EARLY on concatMap for this rule to fire. But if we
-- use INLINE_EARLY on concatMap or fromArray then direct uses of concatMap
-- fromArray (without the RULE) become much slower, this means "concatMap f"
-- in general would become slower. Need to find a solution to this.
--
-- {-# RULES "concatMap fromArray" concatMap fromArray = concatArray #-}


{-# INLINE_LATE foldOneGroup #-}
foldOneGroup
    :: Monad m
    => Int
    -> Fold m a b
    -> a
    -> State K.Stream m a
    -> (State K.Stream m a -> s -> m (Step s a))
    -> s
    -> m (b, Maybe s)
foldOneGroup n (Fold fstep begin done) x gst step state = do
    acc0 <- begin
    acc <- fstep acc0 x
    go SPEC state acc 1

    where

    -- XXX is it strict enough?
    go !_ st !acc i | i < n = do
        r <- step gst st
        case r of
            Yield y s -> do
                acc1 <- fstep acc y
                go SPEC s acc1 (i + 1)
            Skip s -> go SPEC s acc i
            Stop -> do
                res <- done acc
                return (res, Nothing)
    go !_ st acc _ = do
        r <- done acc
        return (r, Just st)

-- groupsOf takes 11 sec to write the file from a stream, whereas just
-- reading in the same file as a stream and folding each element of the stream
-- using (+) takes just 1.5 sec, so we are still pretty slow (7x slow), there
-- is scope to make it faster. There is a possibility of better fusion here.
--
{-# INLINE_NORMAL groupsOf #-}
groupsOf
    :: Monad m
    => Int
    -> Fold m a b
    -> Stream m a
    -> Stream m b
groupsOf n f (Stream step state) =
    n `seq` Stream stepOuter (Just state)

    where

    {-# INLINE_LATE stepOuter #-}
    stepOuter gst (Just st) = do
        -- We retrieve the first element of the stream before we start to fold
        -- a chunk so that we do not return an empty chunk in case the stream
        -- is empty.
        res <- step (adaptState gst) st
        case res of
            Yield x s -> do
                -- XXX how to make sure that stepInner and f get fused
                -- This problem seems to be similar to the concatMap problem
                (r, s1) <- foldOneGroup n f x (adaptState gst) step s
                return $ Yield r s1
            Skip s    -> return $ Skip $ Just s
            Stop      -> return Stop

    stepOuter _ Nothing = return Stop

{-# INLINE_LATE parseOneGroup #-}
parseOneGroup
    :: Monad m
    => Parse m a b
    -> a
    -> State K.Stream m a
    -> (State K.Stream m a -> s -> m (Step s a))
    -> s
    -> m (b, Maybe s)
parseOneGroup (Parse fstep begin done) x gst step state = do
    acc0 <- begin
    let acc01 =
            case acc0 of
                -- we will have to return x as well if we return here
                Success a -> error "needs to consume at least one item"
                Partial a -> a
    acc <- fstep acc01 x
    case acc of
        Partial a -> go SPEC state a
        Success a -> done a >>= \r -> return (r, Just state)

    where

    -- XXX is it strict enough?
    go !_ st !acc = do
        r <- step gst st
        case r of
            Yield y s -> do
                acc' <- fstep acc y
                case acc' of
                    Partial a -> go SPEC s a
                    Success a -> done a >>= \r -> return (r, Just s)
            Skip s -> go SPEC s acc
            Stop -> done acc >>= \r -> return (r, Nothing)

chained
    :: Monad m
    => Parse m a b
    -> Stream m a
    -> Stream m b
chained f (Stream step state) = Stream stepOuter (Just state)

    where

    {-# INLINE_LATE stepOuter #-}
    stepOuter gst (Just st) = do
        -- We retrieve the first element of the stream before we start to fold
        -- a chunk so that we do not return an empty chunk in case the stream
        -- is empty.
        res <- step (adaptState gst) st
        case res of
            Yield x s -> do
                -- XXX how to make sure that stepInner and f get fused
                -- This problem seems to be similar to the concatMap problem
                (r, s1) <- parseOneGroup f x (adaptState gst) step s
                return $ Yield r s1
            Skip s    -> return $ Skip $ Just s
            Stop      -> return Stop

    stepOuter _ Nothing = return Stop

grouped :: Monad m => Fold m a b -> Stream m (a, Bool) -> Stream m b
grouped f (Stream step state) = Stream (stepOuter f) (Just state)

    where

    {-# INLINE_LATE stepOuter #-}
    stepOuter (Fold fstep initial done) gst (Just st) = do
        res <- step (adaptState gst) st
        case res of
            Yield (x,r) s -> do
                acc <- initial
                acc' <- fstep acc x
                if r
                then done acc' >>= \val -> return $ Yield val (Just s)
                else go SPEC s acc'

            Skip s    -> return $ Skip $ Just s
            Stop      -> return Stop

        where

        -- XXX is it strict enough?
        go !_ st !acc = do
            res <- step (adaptState gst) st
            case res of
                Yield (y,r) s -> do
                    acc' <- fstep acc y
                    if r
                    then done acc' >>= \val -> return $ Yield val (Just s)
                    else go SPEC s acc'
                Skip s -> go SPEC s acc
                Stop -> done acc >>= \val -> return $ Yield val Nothing

    stepOuter _ _ Nothing = return Stop

linesWhen :: Monad m => (a -> Bool) -> Fold m a b -> Stream m a -> Stream m b
linesWhen predicate f (Stream step state) = Stream (stepOuter f) (Just state)

    where

    {-# INLINE_LATE stepOuter #-}
    stepOuter (Fold fstep initial done) gst (Just st) = do
        res <- step (adaptState gst) st
        case res of
            Yield x s -> do
                acc <- initial
                if predicate x
                then done acc >>= \val -> return $ Yield val (Just s)
                else do
                    acc' <- fstep acc x
                    go SPEC s acc'

            Skip s    -> return $ Skip $ Just s
            Stop      -> return Stop

        where

        -- XXX is it strict enough?
        go !_ st !acc = do
            res <- step (adaptState gst) st
            case res of
                Yield x s -> do
                    if predicate x
                    then done acc >>= \val -> return $ Yield val (Just s)
                    else do
                        acc' <- fstep acc x
                        go SPEC s acc'
                Skip s -> go SPEC s acc
                Stop -> done acc >>= \val -> return $ Yield val Nothing

    stepOuter _ _ Nothing = return Stop

wordsWhen :: Monad m => (a -> Bool) -> Fold m a b -> Stream m a -> Stream m b
wordsWhen predicate f (Stream step state) = Stream (stepOuter f) (Just state)

    where

    {-# INLINE_LATE stepOuter #-}
    stepOuter (Fold fstep initial done) gst (Just st) = do
        res <- step (adaptState gst) st
        case res of
            Yield x s -> do
                if predicate x
                then return $ Skip (Just s)
                else do
                    acc <- initial
                    acc' <- fstep acc x
                    go SPEC s acc'

            Skip s    -> return $ Skip $ Just s
            Stop      -> return Stop

        where

        -- XXX is it strict enough?
        go !_ st !acc = do
            res <- step (adaptState gst) st
            case res of
                Yield x s -> do
                    if predicate x
                    then done acc >>= \val -> return $ Yield val (Just s)
                    else do
                        acc' <- fstep acc x
                        go SPEC s acc'
                Skip s -> go SPEC s acc
                Stop -> done acc >>= \val -> return $ Yield val Nothing

    stepOuter _ _ Nothing = return Stop

foldBufferWith
    :: (K.IsStream t, Monad m)
    => (Stream m a -> Stream m (t m a))
    -> (Stream m a -> m b)
    -> Stream m a -> Stream m b
foldBufferWith splitter f m = foldBufferWith' f (splitter m)

    where

    foldBufferWith' f (Stream step state) = Stream stepOuter state

        where

        {-# INLINE_LATE stepOuter #-}
        stepOuter gst st = do
            res <- step (adaptState gst) st
            case res of
                Yield x s -> do
                    r <- f (toStreamD x)
                    return $ Yield r s
                Skip s    -> return $ Skip s
                Stop      -> return Stop

data ToArrayState s a =
      ArrayAlloc s
    | ArrayWrite s Int (Array a)
    | ArrayStop

-- XXX This is a more monolithic version of groupsOf and therefore is
-- expected to do better. However, this is 2x slower than using foldGroupsof
-- with the toArray fold.  Need to investigate why.
--
{-# INLINE_NORMAL arrayGroupsOf #-}
arrayGroupsOf
    :: (Monad m, Storable a)
    => Int
    -> Stream m a
    -> Stream m (Array a)
arrayGroupsOf n (Stream step state) =
    n `seq` Stream step' (ArrayAlloc state)

    where

    {-# INLINE_LATE step' #-}
    step' gst (ArrayAlloc st) = do
        res <- step (adaptState gst) st
        return $ case res of
            Yield x s ->
                let !arr = unsafeDupablePerformIO $ unsafeNew n
                    !arr1 = unsafeDangerousPerformIO (unsafeAppend arr x)
                in Skip $ ArrayWrite s 1 arr1
            Skip s -> Skip $ ArrayAlloc s
            Stop -> Skip ArrayStop

    step' gst (ArrayWrite st i arr) | i < n = do
        res <- step (adaptState gst) st
        return $ case res of
            Yield x s ->
                let !arr1 = unsafeDangerousPerformIO (unsafeAppend arr x)
                in Skip $ ArrayWrite s (i + 1) arr1
            Skip s -> Skip $ ArrayWrite s i arr
            Stop -> Yield arr ArrayStop

    step' _ (ArrayWrite st _ arr) = return $ Yield arr (ArrayAlloc st)
    step' _ ArrayStop = return Stop

{-
breakSubstring :: ByteString -- ^ String to search for
               -> ByteString -- ^ String to search in
               -> (ByteString,ByteString) -- ^ Head and tail of string broken at substring
breakSubstring pat =
  case lp of
    0 -> \src -> (empty,src)
    1 -> breakByte (unsafeHead pat)
    _ -> if lp * 8 <= finiteBitSize (0 :: Word)
             then shift
             else karpRabin
  where
    unsafeSplitAt i s = (unsafeTake i s, unsafeDrop i s)
    lp                = length pat
    karpRabin :: ByteString -> (ByteString, ByteString)
    karpRabin src
        | length src < lp = (src,empty)
        | otherwise = search (rollingHash $ unsafeTake lp src) lp
      where
        k           = 2891336453 :: Word32
        rollingHash = foldl' (\h b -> h * k + fromIntegral b) 0
        hp          = rollingHash pat
        m           = k ^ lp
        get = fromIntegral . unsafeIndex src
        search !hs !i
            | hp == hs && pat == unsafeTake lp b = u
            | length src <= i                    = (src,empty) -- not found
            | otherwise                          = search hs' (i + 1)
          where
            u@(_, b) = unsafeSplitAt (i - lp) src
            hs' = hs * k +
                  get i -
                  m * get (i - lp)
    {-# INLINE karpRabin #-}

    shift :: ByteString -> (ByteString, ByteString)
    shift !src
        | length src < lp = (src,empty)
        | otherwise       = search (intoWord $ unsafeTake lp src) lp
      where
        intoWord :: ByteString -> Word
        intoWord = foldl' (\w b -> (w `shiftL` 8) .|. fromIntegral b) 0
        wp   = intoWord pat
        mask = (1 `shiftL` (8 * lp)) - 1
        search !w !i
            | w == wp         = unsafeSplitAt (i - lp) src
            | length src <= i = (src, empty)
            | otherwise       = search w' (i + 1)
          where
            b  = fromIntegral (unsafeIndex src i)
            w' = mask .&. ((w `shiftL` 8) .|. b)
    {-# INLINE shift #-}
    -}

data GroupOnState s a =
      GO_START
    | GO_PREPARE
    | GO_SINGLE s a
    | GO_SHORT_BYTES s
    | GO_KARP_RABIN s
    | GO_FINISHING s
    | GO_DONE

-- XXX specialize for Word8?
-- XXX once we have all IO routines in streamly itself we should be able to
-- remove the MonadIO constraint. We should not need the IO monad.
-- String search algorithms: http://www-igm.univ-mlv.fr/~lecroq/string/index.html

-- | Behavior of this API:
-- 1) When the pattern is empty - whole stream is fed to the fold as a single
-- group.
-- 2) If the stream ends before the pattern is found, the stream is fed to the
-- fold as if the token had been found at the end. We can have an option to
-- discard this. The advantage of this option is that we do not have to buffer
-- the input, we can just stream it to the next fold irrespective of whether
-- the pattern is found or not.
-- 3) The pattern is removed from the stream, only the stream without the
-- pattern is fed to the fold. We can have a control option to say that the
-- separator is also part of the token being folded.
-- XXX We can use a control parameter to control this behavior.
-- XXX since this is a tokenizer we can call it foldTokensOn?

{-# INLINE_NORMAL splitOn #-}
splitOn
    :: forall m a b. (MonadIO m, Storable a, Eq a)
    => (forall n. MonadIO n => Fold n a b)
    -> Array a
    -> Stream m a
    -> Stream m b
splitOn f v@Array{..} (Stream step state) =
    Stream stepOuter GO_START

    where

    byteLen =
        let p = unsafeForeignPtrToPtr aStart
        in aEnd `minusPtr` p

    {-# INLINE fold #-}
    -- fold :: Monad m => Fold m a b -> Stream m a -> m b
    fold (Fold step begin done) = foldxM' step begin done

    {-# INLINE_LATE stepOuter #-}
    stepOuter gst GO_START = return $
        if byteLen == 0
        then Skip $ GO_FINISHING state
        else Skip $ GO_PREPARE

    stepOuter _ GO_PREPARE = return $
        if byteLen == sizeOf (undefined :: a)
        then Skip $ GO_SINGLE state (unsafeIndex v 0)
        -- XXX we can further optimize this with SIMD
        else if sizeOf (undefined :: a) == 1
             then if byteLen * 8 <= finiteBitSize (0 :: Word)
                  then Skip $ GO_SHORT_BYTES state
                  else Skip $ GO_KARP_RABIN state
             else Skip $ GO_KARP_RABIN state

    stepOuter gst (GO_SINGLE st a) = do
        -- Keep the intial state as undefined, if the fold returns prematurely
        -- we will at least know the problem.
        (r, s') <- runStateT (fold f (Stream (stepInner a) (Just (st, False))))
                             undefined
        return $ case s' of
            Just s'' -> Yield r (GO_SINGLE s'' a)
            Nothing  -> Yield r GO_DONE

    stepOuter _ (GO_FINISHING st) = do
        r <- fold f (Stream step st)
        return $ Yield r GO_DONE

    stepOuter _ GO_DONE = return Stop

    {-# INLINE stepInner #-}
    stepInner a _ (Just (st, False)) = do
        -- XXX can we use gst instead of defState?
        r <- lift $ step defState st
        return $ case r of
            Yield x s ->
                if x == a
                then Skip $ Just (s, True)
                else Yield x $ Just (s, False)
            Skip s -> Skip $ Just (s, False)
            Stop   -> Skip Nothing

    stepInner _ _ (Just (st, True)) = do
        put (Just st)
        return Stop

    stepInner _ _ Nothing = do
        put Nothing
        return Stop

------------------------------------------------------------------------------
-- Substreams
------------------------------------------------------------------------------

{-# INLINE_NORMAL isPrefixOf #-}
isPrefixOf :: (Eq a, Monad m) => Stream m a -> Stream m a -> m Bool
isPrefixOf (Stream stepa ta) (Stream stepb tb) = go (ta, tb, Nothing)
  where
    go (sa, sb, Nothing) = do
        r <- stepa defState sa
        case r of
            Yield x sa' -> go (sa', sb, Just x)
            Skip sa'    -> go (sa', sb, Nothing)
            Stop        -> return True

    go (sa, sb, Just x) = do
        r <- stepb defState sb
        case r of
            Yield y sb' ->
                if x == y
                    then go (sa, sb', Nothing)
                    else return False
            Skip sb' -> go (sa, sb', Just x)
            Stop     -> return False

{-# INLINE_NORMAL isSubsequenceOf #-}
isSubsequenceOf :: (Eq a, Monad m) => Stream m a -> Stream m a -> m Bool
isSubsequenceOf (Stream stepa ta) (Stream stepb tb) = go (ta, tb, Nothing)
  where
    go (sa, sb, Nothing) = do
        r <- stepa defState sa
        case r of
            Yield x sa' -> go (sa', sb, Just x)
            Skip sa'    -> go (sa', sb, Nothing)
            Stop        -> return True

    go (sa, sb, Just x) = do
        r <- stepb defState sb
        case r of
            Yield y sb' ->
                if x == y
                    then go (sa, sb', Nothing)
                    else go (sa, sb', Just x)
            Skip sb' -> go (sa, sb', Just x)
            Stop     -> return False

{-# INLINE_NORMAL stripPrefix #-}
stripPrefix
    :: (Eq a, Monad m)
    => Stream m a -> Stream m a -> m (Maybe (Stream m a))
stripPrefix (Stream stepa ta) (Stream stepb tb) = go (ta, tb, Nothing)
  where
    go (sa, sb, Nothing) = do
        r <- stepa defState sa
        case r of
            Yield x sa' -> go (sa', sb, Just x)
            Skip sa'    -> go (sa', sb, Nothing)
            Stop        -> return $ Just (Stream stepb sb)

    go (sa, sb, Just x) = do
        r <- stepb defState sb
        case r of
            Yield y sb' ->
                if x == y
                    then go (sa, sb', Nothing)
                    else return Nothing
            Skip sb' -> go (sa, sb', Just x)
            Stop     -> return Nothing

------------------------------------------------------------------------------
-- Map and Fold
------------------------------------------------------------------------------

-- | Execute a monadic action for each element of the 'Stream'
{-# INLINE_NORMAL mapM_ #-}
mapM_ :: Monad m => (a -> m b) -> Stream m a -> m ()
mapM_ m = runStream . mapM m

------------------------------------------------------------------------------
-- Converting folds
------------------------------------------------------------------------------

-- We use a fold instead to do this.
{-
--  XXX use SPEC
{-# INLINE toArray #-}
toArray :: forall m a. (Monad m, Storable a)
    => Int -> Stream m a -> m (Array a)
toArray limit (Stream step state) = do
    let size = limit * sizeOf (undefined :: a)
        !(fp, cur, end) = unsafePerformIO $ do
            fptr <- mallocPlainForeignPtrBytes size
            let p = unsafeForeignPtrToPtr fptr
            return $ (fptr, p, (p `plusPtr` limit))
    loc <- go state cur end
    -- XXX resizePtr the buffer
    return (Array { vPtr = fp
                    , vLen = limit + (loc `minusPtr` end)
                    , vSize = size})

    where

    go st1 cur1 end = go1 st1 cur1
        where
        go1 st cur = do
            res <- step defState st
            case res of
                Yield _ _ | cur == end -> error "toArray beyond limit"
                Yield x s ->
                    let !r = unsafeDangerousPerformIO $ do
                                poke cur x
                                -- XXX do we need a touch here?
                    in r `seq` go1 s (cur `plusPtr` 1)
                Skip s -> go1 s cur
                Stop   -> return cur
                -}

{-
data ToArrayState a =
      BufAlloc
    | BufWrite (ForeignPtr a) (Ptr a) (Ptr a)
    | BufStop

-- XXX we should never have zero sized chunks if we want to use "null" on a
-- stream of buffers to mean that the stream itself is null.
--
-- XXX use the grouped fold to do this. we need to check the performance
-- though.
--
-- | Group a stream into vectors on n elements each.
{-# INLINE toArrayStreamD #-}
toArrayStreamD
    :: forall m a.
       (Monad m, Storable a)
    => Int -> D.Stream m a -> D.Stream m (Array a)
toArrayStreamD n (D.Stream step state) =
    D.Stream step' (state, BufAlloc)

    where

    size = n * sizeOf (undefined :: a)

    {-# INLINE_LATE step' #-}
    step' _ (st, BufAlloc) =
        let !res = unsafePerformIO $ do
                fptr <- mallocPlainForeignPtrBytes size
                let p = unsafeForeignPtrToPtr fptr
                return $ D.Skip $ (st, BufWrite fptr p (p `plusPtr` n))
        in return res

    step' _ (st, BufWrite fptr cur end) | cur == end =
        return $ D.Yield (Array {vPtr = fptr, vLen = n, vSize = size})
                         (st, BufAlloc)

    step' gst (st, BufWrite fptr cur end) = do
        res <- step (adaptState gst) st
        return $ case res of
            D.Yield x s ->
                let !r = unsafeDangerousPerformIO $ do
                            poke cur x
                            -- XXX do we need a touch here?
                            return $ D.Skip
                                (s, BufWrite fptr (cur `plusPtr` 1) end)
                in r
            D.Skip s -> D.Skip (s, BufWrite fptr cur end)
            D.Stop ->
                -- XXX resizePtr the buffer
                D.Yield (Array { vPtr = fptr
                                , vLen = n + (cur `minusPtr` end)
                                , vSize = size})
                        (st, BufStop)

    step' _ (_, BufStop) = return D.Stop
    -}

-- Convert a direct stream to and from CPS encoded stream
{-# INLINE_LATE toStreamK #-}
toStreamK :: Monad m => Stream m a -> K.Stream m a
toStreamK (Stream step state) = go state
    where
    go st = K.mkStream $ \gst yld sng stp -> do
        r <- step gst st
        case r of
            Yield x s -> yld x (go s)
            Skip  s   -> K.foldStreamShared gst yld sng stp $ go s
            Stop      -> stp

#ifndef DISABLE_FUSION
{-# RULES "fromStreamK/toStreamK fusion"
    forall s. toStreamK (fromStreamK s) = s #-}
{-# RULES "toStreamK/fromStreamK fusion"
    forall s. fromStreamK (toStreamK s) = s #-}
#endif

{-# INLINE fromStreamD #-}
fromStreamD :: (K.IsStream t, Monad m) => Stream m a -> t m a
fromStreamD = K.fromStream . toStreamK

------------------------------------------------------------------------------
-- Transformation by Folding (Scans)
------------------------------------------------------------------------------

-- XXX Is a prescan useful, discarding the last step does not sound useful?  I
-- am not sure about the utility of this function, so this is implemented but
-- not exposed. We can expose it if someone provides good reasons why this is
-- useful.
--
-- XXX We have to execute the stream one step ahead to know that we are at the
-- last step.  The vector implementation of prescan executes the last fold step
-- but does not yield the result. This means we have executed the effect but
-- discarded value. This does not sound right. In this implementation we are
-- not executing the last fold step.
{-# INLINE_NORMAL prescanlM' #-}
prescanlM' :: Monad m => (b -> a -> m b) -> m b -> Stream m a -> Stream m b
prescanlM' f mz (Stream step state) = Stream step' (state, mz)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, prev) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> do
                acc <- prev
                return $ Yield acc (s, f acc x)
            Skip s -> return $ Skip (s, prev)
            Stop   -> return Stop

{-# INLINE prescanl' #-}
prescanl' :: Monad m => (b -> a -> b) -> b -> Stream m a -> Stream m b
prescanl' f z = prescanlM' (\a b -> return (f a b)) (return z)

{-# INLINE_NORMAL postscanxM' #-}
postscanxM' :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Stream m a -> Stream m b
postscanxM' fstep begin done (Stream step state) = do
    Stream step' (state, begin)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, acc) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> do
                old <- acc
                y <- fstep old x
                v <- done y
                v `seq` y `seq` return (Yield v (s, return y))
            Skip s -> return $ Skip (s, acc)
            Stop   -> return Stop

{-# INLINE_NORMAL postscanx' #-}
postscanx' :: Monad m
    => (x -> a -> x) -> x -> (x -> b) -> Stream m a -> Stream m b
postscanx' fstep begin done s =
    postscanxM' (\b a -> return (fstep b a)) (return begin) (return . done) s

-- XXX implement in terms of postscanxM'
--
-- XXX if we make the initial value of the accumulator monadic then should we
-- execute it even if the stream is empty? In that case we would have generated
-- the effect but discarded the value, but that is what a fold does when the
-- stream is empty. Whatever we decide, need to reconcile this with prescan.
-- If we execute the initial value here without even using it then it is ok to
-- execute the last step there as well without using the value.
-- Looking at the duality with right fold, in case of right fold we always
-- perform the action when the construction terminates, so in case of left fold
-- we should perform it only when the reduction starts.
{-# INLINE_NORMAL postscanlM' #-}
postscanlM' :: Monad m => (b -> a -> m b) -> b -> Stream m a -> Stream m b
postscanlM' fstep begin (Stream step state) =
    begin `seq` Stream step' (state, begin)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, acc) = acc `seq` do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> do
                y <- fstep acc x
                y `seq` return (Yield y (s, y))
            Skip s -> return $ Skip (s, acc)
            Stop   -> return Stop

{-# INLINE_NORMAL postscanl' #-}
postscanl' :: Monad m => (a -> b -> a) -> a -> Stream m b -> Stream m a
postscanl' f = postscanlM' (\a b -> return (f a b))

{-# INLINE_NORMAL postscanlM #-}
postscanlM :: Monad m => (b -> a -> m b) -> b -> Stream m a -> Stream m b
postscanlM fstep begin (Stream step state) = Stream step' (state, begin)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, acc) = do
        r <- step (adaptState gst) st
        case r of
            Yield x s -> do
                y <- fstep acc x
                return (Yield y (s, y))
            Skip s -> return $ Skip (s, acc)
            Stop   -> return Stop

{-# INLINE_NORMAL postscanl #-}
postscanl :: Monad m => (a -> b -> a) -> a -> Stream m b -> Stream m a
postscanl f = postscanlM (\a b -> return (f a b))

-- XXX do we need consM strict to evaluate the begin value?
{-# INLINE scanxM' #-}
scanxM' :: Monad m
    => (x -> a -> m x) -> m x -> (x -> m b) -> Stream m a -> Stream m b
scanxM' fstep begin done s =
    (begin >>= \x -> x `seq` done x) `consM` postscanxM' fstep begin done s

{-# INLINE scanx' #-}
scanx' :: Monad m => (x -> a -> x) -> x -> (x -> b) -> Stream m a -> Stream m b
scanx' fstep begin done s =
    scanxM' (\b a -> return (fstep b a)) (return begin) (return . done) s

{-# INLINE_NORMAL scanlM' #-}
scanlM' :: Monad m => (b -> a -> m b) -> b -> Stream m a -> Stream m b
scanlM' fstep begin s = begin `seq` (begin `cons` postscanlM' fstep begin s)

{-# INLINE scanl' #-}
scanl' :: Monad m => (b -> a -> b) -> b -> Stream m a -> Stream m b
scanl' f = scanlM' (\a b -> return (f a b))

{-# INLINE_NORMAL scanlM #-}
scanlM :: Monad m => (b -> a -> m b) -> b -> Stream m a -> Stream m b
scanlM fstep begin s = begin `cons` postscanlM fstep begin s

{-# INLINE scanl #-}
scanl :: Monad m => (b -> a -> b) -> b -> Stream m a -> Stream m b
scanl f = scanlM (\a b -> return (f a b))

{-# INLINE_NORMAL scanl1M #-}
scanl1M :: Monad m => (a -> a -> m a) -> Stream m a -> Stream m a
scanl1M fstep (Stream step state) = Stream step' (state, Nothing)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, Nothing) = do
        r <- step gst st
        case r of
            Yield x s -> return $ Yield x (s, Just x)
            Skip s -> return $ Skip (s, Nothing)
            Stop   -> return Stop

    step' gst (st, Just acc) = do
        r <- step gst st
        case r of
            Yield y s -> do
                z <- fstep acc y
                return $ Yield z (s, Just z)
            Skip s -> return $ Skip (s, Just acc)
            Stop   -> return Stop

{-# INLINE scanl1 #-}
scanl1 :: Monad m => (a -> a -> a) -> Stream m a -> Stream m a
scanl1 f = scanl1M (\x y -> return (f x y))

{-# INLINE_NORMAL scanl1M' #-}
scanl1M' :: Monad m => (a -> a -> m a) -> Stream m a -> Stream m a
scanl1M' fstep (Stream step state) = Stream step' (state, Nothing)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, Nothing) = do
        r <- step gst st
        case r of
            Yield x s -> x `seq` return $ Yield x (s, Just x)
            Skip s -> return $ Skip (s, Nothing)
            Stop   -> return Stop

    step' gst (st, Just acc) = acc `seq` do
        r <- step gst st
        case r of
            Yield y s -> do
                z <- fstep acc y
                z `seq` return $ Yield z (s, Just z)
            Skip s -> return $ Skip (s, Just acc)
            Stop   -> return Stop

{-# INLINE scanl1' #-}
scanl1' :: Monad m => (a -> a -> a) -> Stream m a -> Stream m a
scanl1' f = scanl1M' (\x y -> return (f x y))

{-# INLINE tap #-}
tap :: Monad m => Sink m a -> Stream m a -> Stream m a
tap (Sink fstep) (Stream step state) = Stream step' state

    where

    step' gst st = do
        r <- step gst st
        case r of
            Yield x s -> do
                fstep x
                return $ Yield x s
            Skip s    -> return $ Skip s
            Stop      -> return $ Stop

-------------------------------------------------------------------------------
-- Filtering
-------------------------------------------------------------------------------

{-# INLINE_NORMAL take #-}
take :: Monad m => Int -> Stream m a -> Stream m a
take n (Stream step state) = n `seq` Stream step' (state, 0)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, i) | i < n = do
        r <- step gst st
        return $ case r of
            Yield x s -> Yield x (s, i + 1)
            Skip s    -> Skip (s, i)
            Stop      -> Stop
    step' _ (_, _) = return Stop

{-# INLINE_NORMAL takeWhileM #-}
takeWhileM :: Monad m => (a -> m Bool) -> Stream m a -> Stream m a
takeWhileM f (Stream step state) = Stream step' state
  where
    {-# INLINE_LATE step' #-}
    step' gst st = do
        r <- step gst st
        case r of
            Yield x s -> do
                b <- f x
                return $ if b then Yield x s else Stop
            Skip s -> return $ Skip s
            Stop   -> return Stop

{-# INLINE takeWhile #-}
takeWhile :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
takeWhile f = takeWhileM (return . f)

{-# INLINE_NORMAL drop #-}
drop :: Monad m => Int -> Stream m a -> Stream m a
drop n (Stream step state) = Stream step' (state, Just n)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, Just i)
      | i > 0 = do
          r <- step gst st
          return $
            case r of
              Yield _ s -> Skip (s, Just (i - 1))
              Skip s    -> Skip (s, Just i)
              Stop      -> Stop
      | otherwise = return $ Skip (st, Nothing)

    step' gst (st, Nothing) = do
      r <- step gst st
      return $
        case r of
          Yield x s -> Yield x (s, Nothing)
          Skip  s   -> Skip (s, Nothing)
          Stop      -> Stop

data DropWhileState s a
    = DropWhileDrop s
    | DropWhileYield a s
    | DropWhileNext s

{-# INLINE_NORMAL dropWhileM #-}
dropWhileM :: Monad m => (a -> m Bool) -> Stream m a -> Stream m a
dropWhileM f (Stream step state) = Stream step' (DropWhileDrop state)
  where
    {-# INLINE_LATE step' #-}
    step' gst (DropWhileDrop st) = do
        r <- step gst st
        case r of
            Yield x s -> do
                b <- f x
                if b
                then return $ Skip (DropWhileDrop s)
                else return $ Skip (DropWhileYield x s)
            Skip s -> return $ Skip (DropWhileDrop s)
            Stop -> return Stop

    step' gst (DropWhileNext st) =  do
        r <- step gst st
        case r of
            Yield x s -> return $ Skip (DropWhileYield x s)
            Skip s    -> return $ Skip (DropWhileNext s)
            Stop      -> return Stop

    step' _ (DropWhileYield x st) = return $ Yield x (DropWhileNext st)

{-# INLINE dropWhile #-}
dropWhile :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
dropWhile f = dropWhileM (return . f)

{-# INLINE_NORMAL filterM #-}
filterM :: Monad m => (a -> m Bool) -> Stream m a -> Stream m a
filterM f (Stream step state) = Stream step' state
  where
    {-# INLINE_LATE step' #-}
    step' gst st = do
        r <- step gst st
        case r of
            Yield x s -> do
                b <- f x
                return $ if b
                         then Yield x s
                         else Skip s
            Skip s -> return $ Skip s
            Stop   -> return Stop

{-# INLINE filter #-}
filter :: Monad m => (a -> Bool) -> Stream m a -> Stream m a
filter f = filterM (return . f)

{-# INLINE_NORMAL uniq #-}
uniq :: (Eq a, Monad m) => Stream m a -> Stream m a
uniq (Stream step state) = Stream step' (Nothing, state)
  where
    {-# INLINE_LATE step' #-}
    step' gst (Nothing, st) = do
        r <- step gst st
        case r of
            Yield x s -> return $ Yield x (Just x, s)
            Skip  s   -> return $ Skip  (Nothing, s)
            Stop      -> return Stop
    step' gst (Just x, st)  = do
         r <- step gst st
         case r of
             Yield y s | x == y   -> return $ Skip (Just x, s)
                       | otherwise -> return $ Yield x (Just y, s)
             Skip  s   -> return $ Skip (Just x, s)
             Stop      -> return Stop

------------------------------------------------------------------------------
-- Transformation by Mapping
------------------------------------------------------------------------------

{-# INLINE_NORMAL sequence #-}
sequence :: Monad m => Stream m (m a) -> Stream m a
sequence (Stream step state) = Stream step' state
  where
    {-# INLINE_LATE step' #-}
    step' gst st = do
         r <- step (adaptState gst) st
         case r of
             Yield x s -> x >>= \a -> return (Yield a s)
             Skip s    -> return $ Skip s
             Stop      -> return Stop

------------------------------------------------------------------------------
-- Inserting
------------------------------------------------------------------------------

{-# INLINE_NORMAL insertBy #-}
insertBy :: Monad m => (a -> a -> Ordering) -> a -> Stream m a -> Stream m a
insertBy cmp a (Stream step state) = Stream step' (state, False, Nothing)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, False, _) = do
        r <- step gst st
        case r of
            Yield x s -> case cmp a x of
                GT -> return $ Yield x (s, False, Nothing)
                _  -> return $ Yield a (s, True, Just x)
            Skip s -> return $ Skip (s, False, Nothing)
            Stop   -> return $ Yield a (st, True, Nothing)

    step' _ (_, True, Nothing) = return Stop

    step' gst (st, True, Just prev) = do
        r <- step gst st
        case r of
            Yield x s -> return $ Yield prev (s, True, Just x)
            Skip s    -> return $ Skip (s, True, Just prev)
            Stop      -> return $ Yield prev (st, True, Nothing)

------------------------------------------------------------------------------
-- Deleting
------------------------------------------------------------------------------

{-# INLINE_NORMAL deleteBy #-}
deleteBy :: Monad m => (a -> a -> Bool) -> a -> Stream m a -> Stream m a
deleteBy eq x (Stream step state) = Stream step' (state, False)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, False) = do
        r <- step gst st
        case r of
            Yield y s -> return $
                if eq x y then Skip (s, True) else Yield y (s, False)
            Skip s -> return $ Skip (s, False)
            Stop   -> return Stop

    step' gst (st, True) = do
        r <- step gst st
        case r of
            Yield y s -> return $ Yield y (s, True)
            Skip s -> return $ Skip (s, True)
            Stop   -> return Stop

------------------------------------------------------------------------------
-- Transformation by Map and Filter
------------------------------------------------------------------------------

-- XXX Will this always fuse properly?
{-# INLINE_NORMAL mapMaybe #-}
mapMaybe :: Monad m => (a -> Maybe b) -> Stream m a -> Stream m b
mapMaybe f = fmap fromJust . filter isJust . map f

{-# INLINE_NORMAL mapMaybeM #-}
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> Stream m a -> Stream m b
mapMaybeM f = fmap fromJust . filter isJust . mapM f

------------------------------------------------------------------------------
-- Zipping
------------------------------------------------------------------------------

{-# INLINE_NORMAL indexed #-}
indexed :: Monad m => Stream m a -> Stream m (Int, a)
indexed (Stream step state) = Stream step' (state, 0)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, i) = i `seq` do
         r <- step (adaptState gst) st
         case r of
             Yield x s -> return $ Yield (i, x) (s, i+1)
             Skip    s -> return $ Skip (s, i)
             Stop      -> return Stop

{-# INLINE_NORMAL indexedR #-}
indexedR :: Monad m => Int -> Stream m a -> Stream m (Int, a)
indexedR m (Stream step state) = Stream step' (state, m)
  where
    {-# INLINE_LATE step' #-}
    step' gst (st, i) = i `seq` do
         r <- step (adaptState gst) st
         case r of
             Yield x s -> let i' = i - 1
                          in return $ Yield (i, x) (s, i')
             Skip    s -> return $ Skip (s, i)
             Stop      -> return Stop

{-# INLINE_NORMAL zipWithM #-}
zipWithM :: Monad m
    => (a -> b -> m c) -> Stream m a -> Stream m b -> Stream m c
zipWithM f (Stream stepa ta) (Stream stepb tb) = Stream step (ta, tb, Nothing)
  where
    {-# INLINE_LATE step #-}
    step gst (sa, sb, Nothing) = do
        r <- stepa (adaptState gst) sa
        return $
          case r of
            Yield x sa' -> Skip (sa', sb, Just x)
            Skip sa'    -> Skip (sa', sb, Nothing)
            Stop        -> Stop

    step gst (sa, sb, Just x) = do
        r <- stepb (adaptState gst) sb
        case r of
            Yield y sb' -> do
                z <- f x y
                return $ Yield z (sa, sb', Nothing)
            Skip sb' -> return $ Skip (sa, sb', Just x)
            Stop     -> return Stop

{-# RULES "zipWithM xs xs"
    forall f xs. zipWithM f xs xs = mapM (\x -> f x x) xs #-}

{-# INLINE zipWith #-}
zipWith :: Monad m => (a -> b -> c) -> Stream m a -> Stream m b -> Stream m c
zipWith f = zipWithM (\a b -> return (f a b))

------------------------------------------------------------------------------
-- Comparisions
------------------------------------------------------------------------------

{-# INLINE_NORMAL eqBy #-}
eqBy :: Monad m => (a -> b -> Bool) -> Stream m a -> Stream m b -> m Bool
eqBy eq (Stream step1 t1) (Stream step2 t2) = eq_loop0 SPEC t1 t2
  where
    eq_loop0 !_ s1 s2 = do
      r <- step1 defState s1
      case r of
        Yield x s1' -> eq_loop1 SPEC x s1' s2
        Skip    s1' -> eq_loop0 SPEC   s1' s2
        Stop        -> eq_null s2

    eq_loop1 !_ x s1 s2 = do
      r <- step2 defState s2
      case r of
        Yield y s2'
          | eq x y    -> eq_loop0 SPEC   s1 s2'
          | otherwise -> return False
        Skip    s2'   -> eq_loop1 SPEC x s1 s2'
        Stop          -> return False

    eq_null s2 = do
      r <- step2 defState s2
      case r of
        Yield _ _ -> return False
        Skip s2'  -> eq_null s2'
        Stop      -> return True

-- | Compare two streams lexicographically
{-# INLINE_NORMAL cmpBy #-}
cmpBy
    :: Monad m
    => (a -> b -> Ordering) -> Stream m a -> Stream m b -> m Ordering
cmpBy cmp (Stream step1 t1) (Stream step2 t2) = cmp_loop0 SPEC t1 t2
  where
    cmp_loop0 !_ s1 s2 = do
      r <- step1 defState s1
      case r of
        Yield x s1' -> cmp_loop1 SPEC x s1' s2
        Skip    s1' -> cmp_loop0 SPEC   s1' s2
        Stop        -> cmp_null s2

    cmp_loop1 !_ x s1 s2 = do
      r <- step2 defState s2
      case r of
        Yield y s2' -> case x `cmp` y of
                         EQ -> cmp_loop0 SPEC s1 s2'
                         c  -> return c
        Skip    s2' -> cmp_loop1 SPEC x s1 s2'
        Stop        -> return GT

    cmp_null s2 = do
      r <- step2 defState s2
      case r of
        Yield _ _ -> return LT
        Skip s2'  -> cmp_null s2'
        Stop      -> return EQ

------------------------------------------------------------------------------
-- Merging
------------------------------------------------------------------------------

{-# INLINE_NORMAL mergeByM #-}
mergeByM
    :: (Monad m)
    => (a -> a -> m Ordering) -> Stream m a -> Stream m a -> Stream m a
mergeByM cmp (Stream stepa ta) (Stream stepb tb) =
    Stream step (Just ta, Just tb, Nothing, Nothing)
  where
    {-# INLINE_LATE step #-}

    -- one of the values is missing, and the corresponding stream is running
    step gst (Just sa, sb, Nothing, b) = do
        r <- stepa gst sa
        return $ case r of
            Yield a sa' -> Skip (Just sa', sb, Just a, b)
            Skip sa'    -> Skip (Just sa', sb, Nothing, b)
            Stop        -> Skip (Nothing, sb, Nothing, b)

    step gst (sa, Just sb, a, Nothing) = do
        r <- stepb gst sb
        return $ case r of
            Yield b sb' -> Skip (sa, Just sb', a, Just b)
            Skip sb'    -> Skip (sa, Just sb', a, Nothing)
            Stop        -> Skip (sa, Nothing, a, Nothing)

    -- both the values are available
    step _ (sa, sb, Just a, Just b) = do
        res <- cmp a b
        return $ case res of
            GT -> Yield b (sa, sb, Just a, Nothing)
            _  -> Yield a (sa, sb, Nothing, Just b)

    -- one of the values is missing, corresponding stream is done
    step _ (Nothing, sb, Nothing, Just b) =
            return $ Yield b (Nothing, sb, Nothing, Nothing)

    step _ (sa, Nothing, Just a, Nothing) =
            return $ Yield a (sa, Nothing, Nothing, Nothing)

    step _ (Nothing, Nothing, Nothing, Nothing) = return Stop

{-# INLINE mergeBy #-}
mergeBy
    :: (Monad m)
    => (a -> a -> Ordering) -> Stream m a -> Stream m a -> Stream m a
mergeBy cmp = mergeByM (\a b -> return $ cmp a b)

------------------------------------------------------------------------------
-- Transformation comprehensions
------------------------------------------------------------------------------

{-# INLINE_NORMAL the #-}
the :: (Eq a, Monad m) => Stream m a -> m (Maybe a)
the (Stream step state) = go state
  where
    go st = do
        r <- step defState st
        case r of
            Yield x s -> go' x s
            Skip s    -> go s
            Stop      -> return Nothing
    go' n st = do
        r <- step defState st
        case r of
            Yield x s | x == n -> go' n s
                      | otherwise -> return Nothing
            Skip s -> go' n s
            Stop   -> return (Just n)
