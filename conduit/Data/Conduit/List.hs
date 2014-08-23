{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
-- | Higher-level functions to interact with the elements of a stream. Most of
-- these are based on list functions.
--
-- Note that these functions all deal with individual elements of a stream as a
-- sort of \"black box\", where there is no introspection of the contained
-- elements. Values such as @ByteString@ and @Text@ will likely need to be
-- treated specially to deal with their contents properly (@Word8@ and @Char@,
-- respectively). See the "Data.Conduit.Binary" and "Data.Conduit.Text"
-- modules.
module Data.Conduit.List
    ( -- * Sources
      sourceList
    , sourceNull
    , unfold
    , unfoldM
    , enumFromTo
    , iterate
    , replicate
    , replicateM
      -- * Sinks
      -- ** Pure
    , fold
    , foldMap
    , take
    , drop
    , head
    , peek
    , consume
    , sinkNull
      -- ** Monadic
    , foldMapM
    , foldM
    , mapM_
      -- * Conduits
      -- ** Pure
    , map
    , mapMaybe
    , mapFoldable
    , catMaybes
    , concat
    , concatMap
    , concatMapAccum
    , scanl
    , scan
    , mapAccum
    , groupBy
    , groupOn1
    , isolate
    , filter
      -- ** Monadic
    , mapM
    , iterM
    , scanlM
    , scanM
    , mapAccumM
    , mapMaybeM
    , mapFoldableM
    , concatMapM
    , concatMapAccumM
      -- * Misc
    , sequence
#ifdef QUICKCHECK
    , props
#endif
    ) where

import qualified Prelude
import Prelude
    ( ($), return, (==), (-), Int
    , (.), id, Maybe (..), Monad
    , Bool (..)
    , (>>)
    , (>>=)
    , seq
    , otherwise
    , Enum, Eq
    , maybe
    , (<=)
    )
import Data.Monoid (Monoid, mempty, mappend)
import qualified Data.Foldable as F
import Data.Conduit
import qualified Data.Conduit.Internal as CI
import Data.Conduit.Internal.Fusion
import Control.Monad (when, (<=<), liftM, void)
import Control.Monad.Trans.Class (lift)

#if QUICKCHECK
import Test.Hspec
import Test.QuickCheck
import Control.Monad.Identity (Identity, runIdentity)
import qualified Data.List
import qualified Data.Foldable
import qualified Safe
import qualified Data.Maybe
#endif

-- | Generate a source from a seed value.
--
-- Since 0.4.2
unfold :: Monad m
       => (b -> Maybe (a, b))
       -> b
       -> Producer m a
unfold f =
    go
  where
    go seed =
        case f seed of
            Just (a, seed') -> yield a >> go seed'
            Nothing -> return ()

-- | A monadic unfold.
--
-- Since 1.1.2
unfoldM :: Monad m
        => (b -> m (Maybe (a, b)))
        -> b
        -> Producer m a
unfoldM f =
    go
  where
    go seed = do
        mres <- lift $ f seed
        case mres of
            Just (a, seed') -> yield a >> go seed'
            Nothing -> return ()

sourceList :: Monad m => [a] -> Producer m a
sourceList = Prelude.mapM_ yield

-- | Enumerate from a value to a final value, inclusive, via 'succ'.
--
-- This is generally more efficient than using @Prelude@\'s @enumFromTo@ and
-- combining with @sourceList@ since this avoids any intermediate data
-- structures.
--
-- Subject to fusion
--
-- Since 0.4.2
enumFromTo :: (Enum a, Prelude.Ord a, Monad m)
           => a
           -> a
           -> Producer m a
enumFromTo x y = unstream $ streamSource $ enumFromToS x y
{-# INLINE [0] enumFromTo #-}
{-# RULES "conduit: unstream enumFromTo" forall x y.
    enumFromTo x y = unstream (streamSourcePure $ enumFromToS x y)
  #-}

enumFromToC :: (Enum a, Prelude.Ord a, Monad m)
            => a
            -> a
            -> Producer m a
enumFromToC x0 y =
    loop x0
  where
    loop x
        | x Prelude.> y = return ()
        | otherwise = yield x >> loop (Prelude.succ x)
{-# INLINE [0] enumFromToC #-}

enumFromToS :: (Enum a, Prelude.Ord a, Monad m)
            => a
            -> a
            -> Stream m a ()
enumFromToS x0 y =
    Stream step (return x0)
  where
    step x = return $ if x Prelude.> y
        then Stop ()
        else Emit (Prelude.succ x) x
{-# INLINE [0] enumFromToS #-}

enumFromToS_int :: (Prelude.Integral a, Monad m) => a -> a -> Stream m a ()
enumFromToS_int x0 y = x0 `seq` y `seq` Stream step (return x0)
  where
    step x | x <= y    = return $ Emit (x Prelude.+ 1) x
           | otherwise = return $ Stop ()
{-# INLINE enumFromToS_int #-}

{-# RULES "conduit: enumFromTo<Int>"
      enumFromToS = enumFromToS_int :: Monad m => Int -> Int -> Stream m Int ()
  #-}

-- | Produces an infinite stream of repeated applications of f to x.
iterate :: Monad m => (a -> a) -> a -> Producer m a
iterate f =
    go
  where
    go a = yield a >> go (f a)

-- | Replicate a single value the given number of times.
--
-- Subject to fusion
--
-- Since 1.2.0
replicate :: Monad m => Int -> a -> Producer m a
replicate = replicateC
{-# INLINE [0] replicate #-}
{-# RULES "conduit: unstream replicate" forall i a.
     replicate i a = unstream (streamConduit (replicateC i a) (\_ -> replicateS i a))
  #-}

replicateC :: Monad m => Int -> a -> Producer m a
replicateC cnt0 a =
    loop cnt0
  where
    loop i
        | i <= 0 = return ()
        | otherwise = yield a >> loop (i - 1)
{-# INLINE replicateC #-}

replicateS :: Monad m => Int -> a -> Stream m a ()
replicateS cnt0 a =
    Stream step (return cnt0)
  where
    step cnt
        | cnt <= 0  = return $ Stop ()
        | otherwise = return $ Emit (cnt - 1) a
{-# INLINE replicateS #-}

-- | Replicate a monadic value the given number of times.
--
-- Since 1.2.0
replicateM :: Monad m => Int -> m a -> Producer m a
replicateM = replicateMC
{-# INLINE [0] replicateM #-}
{-# RULES "conduit: unstream replicateM" forall i a.
     replicateM i a = unstream (streamConduit (replicateMC i a) (\_ -> replicateMS i a))
  #-}

replicateMC :: Monad m => Int -> m a -> Producer m a
replicateMC cnt0 ma =
    loop cnt0
  where
    loop i
        | i <= 0 = return ()
        | otherwise = lift ma >>= yield >> loop (i - 1)
{-# INLINE replicateMC #-}

replicateMS :: Monad m => Int -> m a -> Stream m a ()
replicateMS cnt0 ma =
    Stream step (return cnt0)
  where
    step cnt
        | cnt <= 0  = return $ Stop ()
        | otherwise = Emit (cnt - 1) `liftM` ma
{-# INLINE replicateMS #-}

-- | A strict left fold.
--
-- Subject to fusion
--
-- Since 0.3.0
fold :: Monad m
     => (b -> a -> b)
     -> b
     -> Consumer a m b
fold = foldC
{-# INLINE [0] fold #-}
{-# RULES "conduit: unstream fold" forall f b.
        fold f b = unstream (streamConduit (foldC f b) (foldS f b))
  #-}

foldC :: Monad m
      => (b -> a -> b)
      -> b
      -> Consumer a m b
foldC f =
    loop
  where
    loop !accum = await >>= maybe (return accum) (loop . f accum)
{-# INLINE foldC #-}

foldS :: Monad m => (b -> a -> b) -> b -> Stream m a () -> Stream m o b
foldS f b0 (Stream step ms0) =
    Stream step' (liftM (b0, ) ms0)
  where
    step' (!b, s) = do
        res <- step s
        return $ case res of
            Stop () -> Stop b
            Skip s' -> Skip (b, s')
            Emit s' a -> Skip (f b a, s')
{-# INLINE foldS #-}

-- | A monadic strict left fold.
--
-- Subject to fusion
--
-- Since 0.3.0
foldM :: Monad m
      => (b -> a -> m b)
      -> b
      -> Consumer a m b
foldM = foldMC
{-# INLINE [0] foldM #-}
{-# RULES "conduit: unstream foldM" forall f b.
        foldM f b = unstream (streamConduit (foldMC f b) (foldMS f b))
  #-}

foldMC :: Monad m
       => (b -> a -> m b)
       -> b
       -> Consumer a m b
foldMC f =
    loop
  where
    loop accum = do
        await >>= maybe (return accum) go
      where
        go a = do
            accum' <- lift $ f accum a
            accum' `seq` loop accum'
{-# INLINE foldMC #-}

foldMS :: Monad m => (b -> a -> m b) -> b -> Stream m a () -> Stream m o b
foldMS f b0 (Stream step ms0) =
    Stream step' (liftM (b0, ) ms0)
  where
    step' (!b, s) = do
        res <- step s
        case res of
            Stop () -> return $ Stop b
            Skip s' -> return $ Skip (b, s')
            Emit s' a -> do
                b' <- f b a
                return $ Skip (b', s')
{-# INLINE foldMS #-}

-----------------------------------------------------------------
-- These are for cases where- for whatever reason- stream fusion cannot be
-- applied.
connectFold :: Monad m => Source m a -> (b -> a -> b) -> b -> m b
connectFold (CI.ConduitM src0) f =
    go (src0 CI.Done)
  where
    go (CI.Done ()) b = return b
    go (CI.HaveOutput src _ a) b = go src Prelude.$! f b a
    go (CI.NeedInput _ c) b = go (c ()) b
    go (CI.Leftover src ()) b = go src b
    go (CI.PipeM msrc) b = do
        src <- msrc
        go src b
{-# INLINE connectFold #-}
{-# RULES "conduit: $$ fold" forall src f b. src $$ fold f b = connectFold src f b #-}

connectFoldM :: Monad m => Source m a -> (b -> a -> m b) -> b -> m b
connectFoldM (CI.ConduitM src0) f =
    go (src0 CI.Done)
  where
    go (CI.Done ()) b = return b
    go (CI.HaveOutput src _ a) b = do
        !b' <- f b a
        go src b'
    go (CI.NeedInput _ c) b = go (c ()) b
    go (CI.Leftover src ()) b = go src b
    go (CI.PipeM msrc) b = do
        src <- msrc
        go src b
{-# INLINE connectFoldM #-}
{-# RULES "conduit: $$ foldM" forall src f b. src $$ foldM f b = connectFoldM src f b #-}
-----------------------------------------------------------------

-- | A monoidal strict left fold.
--
-- Since 0.5.3
foldMap :: (Monad m, Monoid b)
        => (a -> b)
        -> Consumer a m b
foldMap f =
    fold combiner mempty
  where
    combiner accum = mappend accum . f

-- | A monoidal strict left fold in a Monad.
--
-- Since 1.0.8
foldMapM :: (Monad m, Monoid b)
        => (a -> m b)
        -> Consumer a m b
foldMapM f =
    foldM combiner mempty
  where
    combiner accum = liftM (mappend accum) . f

-- | Apply the action to all values in the stream.
--
-- Since 0.3.0
mapM_ :: Monad m
      => (a -> m ())
      -> Consumer a m ()
mapM_ f = awaitForever $ lift . f
{-# INLINE [1] mapM_ #-}

srcMapM_ :: Monad m => Source m a -> (a -> m ()) -> m ()
srcMapM_ (CI.ConduitM src) f =
    go (src CI.Done)
  where
    go (CI.Done ()) = return ()
    go (CI.PipeM mp) = mp >>= go
    go (CI.Leftover p ()) = go p
    go (CI.HaveOutput p _ o) = f o >> go p
    go (CI.NeedInput _ c) = go (c ())
{-# INLINE srcMapM_ #-}
{-# RULES "conduit: connect to mapM_" forall f src. src $$ mapM_ f = srcMapM_ src f #-}

-- | Ignore a certain number of values in the stream. This function is
-- semantically equivalent to:
--
-- > drop i = take i >> return ()
--
-- However, @drop@ is more efficient as it does not need to hold values in
-- memory.
--
-- Since 0.3.0
drop :: Monad m
     => Int
     -> Consumer a m ()
drop =
    loop
  where
    loop i | i <= 0 = return ()
    loop count = await >>= maybe (return ()) (\_ -> loop (count - 1))

-- | Take some values from the stream and return as a list. If you want to
-- instead create a conduit that pipes data to another sink, see 'isolate'.
-- This function is semantically equivalent to:
--
-- > take i = isolate i =$ consume
--
-- Since 0.3.0
take :: Monad m
     => Int
     -> Consumer a m [a]
take =
    loop id
  where
    loop front count | count <= 0 = return $ front []
    loop front count = await >>= maybe
        (return $ front [])
        (\x -> loop (front .(x:)) (count - 1))

-- | Take a single value from the stream, if available.
--
-- Since 0.3.0
head :: Monad m => Consumer a m (Maybe a)
head = await

-- | Look at the next value in the stream, if available. This function will not
-- change the state of the stream.
--
-- Since 0.3.0
peek :: Monad m => Consumer a m (Maybe a)
peek = await >>= maybe (return Nothing) (\x -> leftover x >> return (Just x))

-- | Apply a transformation to all values in a stream.
--
-- Subject to fusion
--
-- Since 0.3.0
map :: Monad m => (a -> b) -> Conduit a m b
map = mapC
{-# INLINE [0] map #-}
{-# RULES "conduit: unstream map" forall f.
    map f = unstream (streamConduit (mapC f) (mapS f))
  #-}

mapC :: Monad m => (a -> b) -> Conduit a m b
mapC f = awaitForever $ yield . f
{-# INLINE mapC #-}

mapS :: Monad m => (a -> b) -> Stream m a r -> Stream m b r
mapS f (Stream step ms0) =
    Stream step' ms0
  where
    step' s = do
        res <- step s
        return $ case res of
            Stop r -> Stop r
            Emit s' a -> Emit s' (f a)
            Skip s' -> Skip s'
{-# INLINE mapS #-}

-- Since a Source never has any leftovers, fusion rules on it are safe.
{-
{-# RULES "conduit: source/map fusion =$=" forall f src. src =$= map f = mapFuseRight src f #-}

mapFuseRight :: Monad m => Source m a -> (a -> b) -> Source m b
mapFuseRight src f = CIC.mapOutput f src
{-# INLINE mapFuseRight #-}
-}

{-

It might be nice to include these rewrite rules, but they may have subtle
differences based on leftovers.

{-# RULES "conduit: map-to-mapOutput pipeL" forall f src. pipeL src (map f) = mapOutput f src #-}
{-# RULES "conduit: map-to-mapOutput $=" forall f src. src $= (map f) = mapOutput f src #-}
{-# RULES "conduit: map-to-mapOutput pipe" forall f src. pipe src (map f) = mapOutput f src #-}
{-# RULES "conduit: map-to-mapOutput >+>" forall f src. src >+> (map f) = mapOutput f src #-}

{-# RULES "conduit: map-to-mapInput pipeL" forall f sink. pipeL (map f) sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}
{-# RULES "conduit: map-to-mapInput =$" forall f sink. map f =$ sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}
{-# RULES "conduit: map-to-mapInput pipe" forall f sink. pipe (map f) sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}
{-# RULES "conduit: map-to-mapInput >+>" forall f sink. map f >+> sink = mapInput f (Prelude.const Prelude.Nothing) sink #-}

{-# RULES "conduit: map-to-mapOutput =$=" forall f con. con =$= map f = mapOutput f con #-}
{-# RULES "conduit: map-to-mapInput =$=" forall f con. map f =$= con = mapInput f (Prelude.const Prelude.Nothing) con #-}

{-# INLINE [1] map #-}

-}

-- | Apply a monadic transformation to all values in a stream.
--
-- If you do not need the transformed values, and instead just want the monadic
-- side-effects of running the action, see 'mapM_'.
--
-- Subject to fusion
--
-- Since 0.3.0
mapM :: Monad m => (a -> m b) -> Conduit a m b
mapM = mapMC
{-# INLINE [0] mapM #-}
{-# RULES "conduit: unstream mapM" forall f.
    mapM f = unstream (streamConduit (mapMC f) (mapMS f))
  #-}

mapMC :: Monad m => (a -> m b) -> Conduit a m b
mapMC f = awaitForever $ \a -> lift (f a) >>= yield
{-# INLINE mapMC #-}

mapMS :: Monad m => (a -> m b) -> Stream m a r -> Stream m b r
mapMS f (Stream step ms0) =
    Stream step' ms0
  where
    step' s = do
        res <- step s
        case res of
            Stop r -> return $ Stop r
            Emit s' a -> Emit s' `liftM` f a
            Skip s' -> return $ Skip s'
{-# INLINE mapMS #-}

-- | Apply a monadic action on all values in a stream.
--
-- This @Conduit@ can be used to perform a monadic side-effect for every
-- value, whilst passing the value through the @Conduit@ as-is.
--
-- > iterM f = mapM (\a -> f a >>= \() -> return a)
--
-- Since 0.5.6
iterM :: Monad m => (a -> m ()) -> Conduit a m a
iterM f = awaitForever $ \a -> lift (f a) >> yield a

-- | Apply a transformation that may fail to all values in a stream, discarding
-- the failures.
--
-- Since 0.5.1
mapMaybe :: Monad m => (a -> Maybe b) -> Conduit a m b
mapMaybe f = awaitForever $ maybe (return ()) yield . f

-- | Apply a monadic transformation that may fail to all values in a stream,
-- discarding the failures.
--
-- Since 0.5.1
mapMaybeM :: Monad m => (a -> m (Maybe b)) -> Conduit a m b
mapMaybeM f = awaitForever $ maybe (return ()) yield <=< lift . f

-- | Filter the @Just@ values from a stream, discarding the @Nothing@  values.
--
-- Since 0.5.1
catMaybes :: Monad m => Conduit (Maybe a) m a
catMaybes = awaitForever $ maybe (return ()) yield

-- | Generalization of 'catMaybes'. It puts all values from
--   'F.Foldable' into stream.
--
-- Since 1.0.6
concat :: (Monad m, F.Foldable f) => Conduit (f a) m a
concat = awaitForever $ F.mapM_ yield

-- | Apply a transformation to all values in a stream, concatenating the output
-- values.
--
-- Since 0.3.0
concatMap :: Monad m => (a -> [b]) -> Conduit a m b
concatMap f = awaitForever $ sourceList . f

-- | Apply a monadic transformation to all values in a stream, concatenating
-- the output values.
--
-- Since 0.3.0
concatMapM :: Monad m => (a -> m [b]) -> Conduit a m b
concatMapM f = awaitForever $ sourceList <=< lift . f

-- | 'concatMap' with an accumulator.
--
-- Since 0.3.0
concatMapAccum :: Monad m => (a -> accum -> (accum, [b])) -> accum -> Conduit a m b
concatMapAccum f x0 = void (mapAccum f x0) =$= concat

-- | Deprecated synonym for @mapAccum@
--
-- Since 1.0.6
scanl :: Monad m => (a -> s -> (s, b)) -> s -> Conduit a m b
scanl f s = void $ mapAccum f s
{-# DEPRECATED scanl "Use mapAccum instead" #-}

-- | Deprecated synonym for @mapAccumM@
--
-- Since 1.0.6
scanlM :: Monad m => (a -> s -> m (s, b)) -> s -> Conduit a m b
scanlM f s = void $ mapAccumM f s
{-# DEPRECATED scanlM "Use mapAccumM instead" #-}

-- | Analog of @mapAccumL@ for lists.
--
-- Since 1.1.1
mapAccum :: Monad m => (a -> s -> (s, b)) -> s -> ConduitM a b m s
mapAccum f =
    loop
  where
    loop s = await >>= maybe (return s) go
      where
        go a = case f a s of
                 (s', b) -> yield b >> loop s'

-- | Monadic `mapAccum`.
--
-- Since 1.1.1
mapAccumM :: Monad m => (a -> s -> m (s, b)) -> s -> ConduitM a b m s
mapAccumM f =
    loop
  where
    loop s = await >>= maybe (return s) go
      where
        go a = do (s', b) <- lift $ f a s
                  yield b
                  loop s'

-- | Analog of 'Prelude.scanl' for lists.
--
-- Since 1.1.1
scan :: Monad m => (a -> b -> b) -> b -> ConduitM a b m b
scan f =
    mapAccum $ \a b -> let b' = f a b in (b', b')

-- | Monadic @scanl@.
--
-- Since 1.1.1
scanM :: Monad m => (a -> b -> m b) -> b -> ConduitM a b m b
scanM f =
    mapAccumM $ \a b -> do b' <- f a b
                           return (b', b')

-- | 'concatMapM' with an accumulator.
--
-- Since 0.3.0
concatMapAccumM :: Monad m => (a -> accum -> m (accum, [b])) -> accum -> Conduit a m b
concatMapAccumM f x0 = void (mapAccumM f x0) =$= concat


-- | Generalization of 'mapMaybe' and 'concatMap'. It applies function
-- to all values in a stream and send values inside resulting
-- 'Foldable' downstream.
--
-- Since 1.0.6
mapFoldable :: (Monad m, F.Foldable f) => (a -> f b) -> Conduit a m b
mapFoldable f = awaitForever $ F.mapM_ yield . f

-- | Monadic variant of 'mapFoldable'.
--
-- Since 1.0.6
mapFoldableM :: (Monad m, F.Foldable f) => (a -> m (f b)) -> Conduit a m b
mapFoldableM f = awaitForever $ F.mapM_ yield <=< lift . f


-- | Consume all values from the stream and return as a list. Note that this
-- will pull all values into memory. For a lazy variant, see
-- "Data.Conduit.Lazy".
--
-- Subject to fusion
--
-- Since 0.3.0
consume :: Monad m => Consumer a m [a]
consume = consumeC
{-# INLINE [0] consume #-}
{-# RULES "conduit: unstream consume" consume = unstream (streamConduit consumeC consumeS) #-}

consumeC :: Monad m => Consumer a m [a]
consumeC =
    loop id
  where
    loop front = await >>= maybe (return $ front []) (\x -> loop $ front . (x:))
{-# INLINE consumeC #-}

consumeS :: Monad m => Stream m a () -> Stream m o [a]
consumeS (Stream step ms0) =
    Stream step' (liftM (id,) ms0)
  where
    step' (front, s) = do
        res <- step s
        return $ case res of
            Stop () -> Stop (front [])
            Skip s' -> Skip (front, s')
            Emit s' a -> Skip (front . (a:), s')
{-# INLINE consumeS #-}

-- | Grouping input according to an equality function.
--
-- Since 0.3.0
groupBy :: Monad m => (a -> a -> Bool) -> Conduit a m [a]
groupBy f =
    start
  where
    start = await >>= maybe (return ()) (loop id)

    loop rest x =
        await >>= maybe (yield (x : rest [])) go
      where
        go y
            | f x y     = loop (rest . (y:)) x
            | otherwise = yield (x : rest []) >> loop id y


-- | 'groupOn1' is similar to @groupBy id@
--
-- returns a pair, indicating there are always 1 or more items in the grouping.
-- This is designed to be converted into a NonEmpty structure
-- but it avoids a dependency on another package
--
-- > import Data.List.NonEmpty
-- >
-- > groupOn1 :: (Monad m, Eq b) => (a -> b) -> Conduit a m (NonEmpty a)
-- > groupOn1 f = CL.groupOn1 f =$= CL.map (uncurry (:|))
--
-- Since 1.1.7
groupOn1 :: (Monad m, Eq b)
         => (a -> b)
         -> Conduit a m (a, [a])
groupOn1 f =
    start
  where
    start = await >>= maybe (return ()) (loop id)

    loop rest x =
        await >>= maybe (yield (x, rest [])) go
      where
        go y
            | f x == f y = loop (rest . (y:)) x
            | otherwise  = yield (x, rest []) >> loop id y


-- | Ensure that the inner sink consumes no more than the given number of
-- values. Note this this does /not/ ensure that the sink consumes all of those
-- values. To get the latter behavior, combine with 'sinkNull', e.g.:
--
-- > src $$ do
-- >     x <- isolate count =$ do
-- >         x <- someSink
-- >         sinkNull
-- >         return x
-- >     someOtherSink
-- >     ...
--
-- Since 0.3.0
isolate :: Monad m => Int -> Conduit a m a
isolate =
    loop
  where
    loop count | count <= 0 = return ()
    loop count = await >>= maybe (return ()) (\x -> yield x >> loop (count - 1))

-- | Keep only values in the stream passing a given predicate.
--
-- Since 0.3.0
filter :: Monad m => (a -> Bool) -> Conduit a m a
filter f = awaitForever $ \i -> when (f i) (yield i)

filterFuseRight :: Monad m => Source m a -> (a -> Bool) -> Source m a
filterFuseRight (CI.ConduitM src) f = CI.ConduitM $ \rest -> let
    go (CI.Done ()) = rest ()
    go (CI.PipeM mp) = CI.PipeM (liftM go mp)
    go (CI.Leftover p i) = CI.Leftover (go p) i
    go (CI.HaveOutput p c o)
        | f o = CI.HaveOutput (go p) c o
        | otherwise = go p
    go (CI.NeedInput p c) = CI.NeedInput (go . p) (go . c)
    in go (src CI.Done)
-- Intermediate finalizers are dropped, but this is acceptable: the next
-- yielded value would be demanded by downstream in any event, and that new
-- finalizer will always override the existing finalizer.
{-# RULES "conduit: source/filter fusion =$=" forall f src. src =$= filter f = filterFuseRight src f #-}
{-# INLINE filterFuseRight #-}

-- | Ignore the remainder of values in the source. Particularly useful when
-- combined with 'isolate'.
--
-- Since 0.3.0
sinkNull :: Monad m => Consumer a m ()
sinkNull = awaitForever $ \_ -> return ()
{-# RULES "conduit: connect to sinkNull" forall src. src $$ sinkNull = srcSinkNull src #-}

srcSinkNull :: Monad m => Source m a -> m ()
srcSinkNull (CI.ConduitM src) =
    go (src CI.Done)
  where
    go (CI.Done ()) = return ()
    go (CI.PipeM mp) = mp >>= go
    go (CI.Leftover p ()) = go p
    go (CI.HaveOutput p _ _) = go p
    go (CI.NeedInput _ c) = go (c ())
{-# INLINE srcSinkNull #-}

-- | A source that outputs no values. Note that this is just a type-restricted
-- synonym for 'mempty'.
--
-- Since 0.3.0
sourceNull :: Monad m => Producer m a
sourceNull = return ()

-- | Run a @Pipe@ repeatedly, and output its result value downstream. Stops
-- when no more input is available from upstream.
--
-- Since 0.5.0
sequence :: Monad m
         => Consumer i m o -- ^ @Pipe@ to run repeatedly
         -> Conduit i m o
sequence sink =
    self
  where
    self = awaitForever $ \i -> leftover i >> sink >>= yield

#ifdef QUICKCHECK
props = describe "Data.Conduit.List" $ do
    qit "unfold" $
        \(getBlind -> f, initial :: Int) ->
            unfold f initial `checkInfiniteProducer`
            (Data.List.unfoldr f initial :: [Int])
    todo "unfoldM"
    qit "sourceList" $
        \(xs :: [Int]) ->
            sourceList xs `checkProducer` xs
    qit "enumFromToC" $
        \(fr :: Small Int, to :: Small Int) ->
            enumFromToC fr to `checkProducer`
            Prelude.enumFromTo fr to
    qit "enumFromToS" $
        \(fr :: Small Int, to :: Small Int) ->
            enumFromToS fr to `checkStreamProducer`
            Prelude.enumFromTo fr to
    qit "enumFromToS_int" $
        \(getSmall -> fr :: Int, getSmall -> to :: Int) ->
            enumFromToS_int fr to `checkStreamProducer`
            Prelude.enumFromTo fr to
    qit "iterate" $
        \(getBlind -> f, initial :: Int) ->
            iterate f initial `checkInfiniteProducer`
            Prelude.iterate f initial
    qit "replicateC" $
        \(getSmall -> n) ->
            replicateC n '0' `checkProducer`
            Prelude.replicate n '0'
    qit "replicateS" $
        \(getSmall -> n) ->
            replicateS n '0' `checkStreamProducer`
            Prelude.replicate n '0'
    todo "replicateMC"
    todo "replicateMS"
    qit "foldC" $
        \(getBlind -> f, initial :: Int) ->
            foldC f initial `checkConsumer`
            Data.List.foldl' f initial
    {-qit "foldS" $
        \(getBlind -> f, initial :: Int) ->
            foldC f initial `checkStreamConsumer`
            Data.List.foldl' f initial-}
    todo "foldMC"
    todo "foldMS"
    todo "connectFold"
    todo "connectFoldM"
    qit "foldMap" $
        \(getBlind -> (f :: Int -> Sum Int)) ->
            foldMap f `checkConsumer`
            Data.Foldable.foldMap f
    todo "mapM_"
    todo "srcMapM_"
    {-qit "drop" $
        \(getSmall -> n) ->
            drop n `checkConsumer`
            Prelude.drop n-}
    qit "take" $
        \(getSmall -> n) ->
            take n `checkConsumer`
            Prelude.take n
    qit "head" $
        \() ->
            head `checkConsumer`
            Safe.headMay
    qit "peek" $
        \() ->
            peek `checkConsumer`
            Safe.headMay
    qit "mapC" $
        \(getBlind -> f) ->
            mapC f `checkConduit`
            (Prelude.map f :: [Int] -> [Int])
    {-qit "mapS" $
        \(getBlind -> f) ->
            mapS f `checkStreamConduit`
            Prelude.map f-}
    todo "mapMC"
    todo "mapMS"
    todo "iterM"
    qit "mapMaybe" $
        \(getBlind -> f) ->
            mapMaybe f `checkConduit`
            (Data.Maybe.mapMaybe f :: [Int] -> [Int])
    todo "mapMaybeM"
    qit "catMaybes" $
        \() ->
            catMaybes `checkConduit`
            (Data.Maybe.catMaybes :: [Maybe Int] -> [Int])
    qit "concat" $
        \() ->
            concat `checkConduit`
            (Prelude.concat :: [[Int]] -> [Int])
    qit "concatMap" $
        \(getBlind -> f) ->
            concatMap f `checkConduit`
            (Prelude.concatMap f :: [Int] -> [Int])
    todo "concatMapM"
    todo "concatMapAccum"
    todo "mapAccum"
    todo "mapAccumM"
    {-qit "scan" $
        \(getBlind -> f, initial :: Int) ->
            scan f initial `checkConduit`
            Prelude.scanr f initial-}
    todo "scanM"
    todo "concatMapAccumM"
    todo "mapFoldable"
    todo "mapFoldableM"
    qit "consumeC" $
        \() ->
            consumeC `checkConsumer`
            id
    todo "consumeS"
    qit "groupBy" $
        \(getBlind -> f) ->
            groupBy f `checkConduit`
            (Data.List.groupBy f :: [Int] -> [[Int]])
    todo "groupOn1"
    qit "isolate" $
        \n ->
            isolate n `checkConduit`
            (Data.List.take n :: [Int] -> [Int])
    qit "filter" $
        \(getBlind -> f) ->
            filter f `checkConduit`
            (Data.List.filter f :: [Int] -> [Int])
    todo "filterFuseRight"
    todo "sinkNull"
    todo "srcSinkNull"
    qit "sourceNull" $
        \() ->
            sourceNull `checkProducer`
            ([] :: [Int])
    todo "sequence"

todo n = it n $ True

qit n f = it n $ property $ forAll arbitrary f

checkProducer :: (Prelude.Show a, Eq a) => Source Identity a -> [a] -> Property
checkProducer c l = runIdentity (c $$ consume) === l

checkStreamProducer :: (Prelude.Show a, Eq a) => Stream Identity a () -> [a] -> Property
checkStreamProducer s l = runIdentity (unstream (streamSource s) $$ consume) === l

checkInfiniteProducer :: (Prelude.Show a, Eq a) => Source Identity a -> [a] -> Property
checkInfiniteProducer s l = checkProducer (s $= isolate 10) (Prelude.take 10 l)

{- TODO
checkInfiniteStreamProducer :: (Prelude.Show a, Eq a) => Stream Identity a () -> [a] -> Property
checkInfiniteStreamProducer s l = checkStreamProducer (fuseStream s isolate) l
-}

checkConsumer :: (Prelude.Show b, Eq b) => Consumer Int Identity b -> ([Int] -> b) -> Property
checkConsumer c l = forAll arbitrary $ \xs ->
    runIdentity (sourceList xs $$ c) === l xs

{- TODO
checkStreamConsumer :: (Prelude.Show b, Eq b) => Stream Identity Int b -> ([Int] -> b) -> Property
checkStreamConsumer = forAll arbitrary $ \xs ->
    runIdentity (sourceList xs $$ c) === l xs
-}

checkConduit :: (Prelude.Show a, Arbitrary a, Prelude.Show b, Eq b) => Conduit a Identity b -> ([a] -> [b]) -> Property
checkConduit c l = forAll arbitrary $ \xs ->
    runIdentity (sourceList xs $= c $$ consume) == l xs

-- checkStreamConduit :: Stream Identity Int Int -> ([Int] -> [Int]) -> Property
-- checkStreamConduit c l = forAll arbitrary $ \xs ->
--     runIdentity (unstream (streamSource s))

-- Prefer this to creating an orphan instance for Data.Monoid.Sum:

newtype Sum a = Sum a
  deriving (Eq, Prelude.Show, Arbitrary)

instance Prelude.Num a => Monoid (Sum a) where
  mempty = Sum 0
  mappend (Sum x) (Sum y) = Sum $ x Prelude.+ y

#endif
