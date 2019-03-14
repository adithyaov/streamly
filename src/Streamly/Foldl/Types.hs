{-# LANGUAGE CPP                       #-}
{-# LANGUAGE ExistentialQuantification          #-}

-- |
-- Module      : Streamly.Foldl.Types
-- Copyright   : (c) 2019 Composewell Technologies
--               (c) 2013 Gabriel Gonzalez
-- License     : BSD3
-- Maintainer  : harendra.kumar@gmail.com
-- Stability   : experimental
-- Portability : GHC

module Streamly.Foldl.Types
    (
      Pair (..)
    , Foldl (..)
    )
where

import Control.Applicative (liftA2)

-- XXX use UNPACKED?
data Pair a b = Pair !a !b

------------------------------------------------------------------------------
-- Monadic left folds
------------------------------------------------------------------------------

-- | Represents a left fold from an input stream of values of type @a@ to a
-- single value of type @b@ in 'Monad' @m@. Each step of the fold can be
-- applied incrementally by explicitly calling the @step@ function and the
-- accumulated value can be extracted at any point by calling the @extract@
-- function.
data Foldl m a b =
  -- | @Foldl @ @ step @ @ initial @ @ extract@
  forall x. Foldl (x -> a -> m x) (m x) (x -> m b)

instance Applicative m => Functor (Foldl m a) where
    {-# INLINE fmap #-}
    fmap f (Foldl step start done) = Foldl step start done'
        where
        done' x = fmap f $! done x

    {-# INLINE (<$) #-}
    (<$) b = \_ -> pure b

instance Applicative m => Applicative (Foldl m a) where
    {-# INLINE pure #-}
    pure b = Foldl (\() _ -> pure ()) (pure ()) (\() -> pure b)

    {-# INLINE (<*>) #-}
    (Foldl stepL beginL doneL) <*> (Foldl stepR beginR doneR) =
        let step (Pair xL xR) a = Pair <$> stepL xL a <*> stepR xR a
            begin = Pair <$> beginL <*> beginR
            done (Pair xL xR) = doneL xL <*> doneR xR
        in  Foldl step begin done

    {-# INLINE (<*) #-}
    (<*) m = \_ -> m

    {-# INLINE (*>) #-}
    _ *> m = m

instance (Semigroup b, Monad m) => Semigroup (Foldl m a b) where
    {-# INLINE (<>) #-}
    (<>) = liftA2 (<>)

instance (Monoid b, Monad m) => Monoid (Foldl m a b) where
    {-# INLINE mempty #-}
    mempty = pure mempty

    {-# INLINE mappend #-}
    mappend = (<>)

instance (Monad m, Num b) => Num (Foldl m a b) where
    {-# INLINE fromInteger #-}
    fromInteger = pure . fromInteger

    {-# INLINE negate #-}
    negate = fmap negate

    {-# INLINE abs #-}
    abs = fmap abs

    {-# INLINE signum #-}
    signum = fmap signum

    {-# INLINE (+) #-}
    (+) = liftA2 (+)

    {-# INLINE (*) #-}
    (*) = liftA2 (*)

    {-# INLINE (-) #-}
    (-) = liftA2 (-)

instance (Monad m, Fractional b) => Fractional (Foldl m a b) where
    {-# INLINE fromRational #-}
    fromRational = pure . fromRational

    {-# INLINE recip #-}
    recip = fmap recip

    {-# INLINE (/) #-}
    (/) = liftA2 (/)

instance (Monad m, Floating b) => Floating (Foldl m a b) where
    {-# INLINE pi #-}
    pi = pure pi

    {-# INLINE exp #-}
    exp = fmap exp

    {-# INLINE sqrt #-}
    sqrt = fmap sqrt

    {-# INLINE log #-}
    log = fmap log

    {-# INLINE sin #-}
    sin = fmap sin

    {-# INLINE tan #-}
    tan = fmap tan

    {-# INLINE cos #-}
    cos = fmap cos

    {-# INLINE asin #-}
    asin = fmap asin

    {-# INLINE atan #-}
    atan = fmap atan

    {-# INLINE acos #-}
    acos = fmap acos

    {-# INLINE sinh #-}
    sinh = fmap sinh

    {-# INLINE tanh #-}
    tanh = fmap tanh

    {-# INLINE cosh #-}
    cosh = fmap cosh

    {-# INLINE asinh #-}
    asinh = fmap asinh

    {-# INLINE atanh #-}
    atanh = fmap atanh

    {-# INLINE acosh #-}
    acosh = fmap acosh

    {-# INLINE (**) #-}
    (**) = liftA2 (**)

    {-# INLINE logBase #-}
    logBase = liftA2 logBase
