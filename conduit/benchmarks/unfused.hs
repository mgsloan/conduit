{-# LANGUAGE RankNTypes, BangPatterns #-}
-- Compare low-level, fused, unfused, and partially fused
-- import Data.Conduit
import qualified Data.Conduit as C
import           Data.Conduit hiding (($$), (=$=), (=$), ($=))
import qualified Data.Conduit.List as CL
import           Data.Conduit.List (ConduitM'(..), Producer', Consumer', Conduit')
import           Data.Conduit.Internal (Step (..), Stream (..), unstream, StreamConduit (..))
import           Criterion.Main
import           Data.Functor.Identity (runIdentity)
import           Control.Applicative
import           Data.Void
import           Debug.Trace
infixr 0 $$
infixl 1 $=
infixr 2 =$
infixr 2 =$=

connectStream :: Monad m
               => (Stream m () () -> Stream m o ())
               -> (Stream m o () -> Stream m Void r)
               -> m r
connectStream stream f =
    run $ f $ stream $ Stream emptyStep (return ())
  where
    emptyStep _ = return $ Stop ()
    run (Stream step ms0) =
        ms0 >>= loop
      where
        loop s = do
            res <- step s
            case res of
                Stop r -> return r
                Skip s' -> loop s'
                Emit _ o -> absurd o
{-# INLINE connectStream #-}

($$) :: Monad m => Producer' m a -> Consumer' a m b -> m b
(ConduitM' _ (Just ps)) $$ (ConduitM' _ (Just cs)) =
    connectStream ps cs
(ConduitM' pc _) $$ (ConduitM' cc _) =
    pc C.$$ cc
{-# INLINE ($$) #-}

(=$=) :: Monad m => Conduit' a m b -> ConduitM' b c m r -> ConduitM' a c m r
(ConduitM' pc mps) =$= (ConduitM' cc mcs) =
    ConduitM' (pc C.=$= cc) (flip (.) <$> mps <*> mcs)
{-# INLINE (=$=) #-}

($=) :: Monad m => Conduit' a m b -> ConduitM' b c m r -> ConduitM' a c m r
($=) = (=$=)
{-# INLINE ($=) #-}

(=$) :: Monad m => Conduit' a m b -> ConduitM' b c m r -> ConduitM' a c m r
(=$) = (=$=)
{-# INLINE (=$) #-}

-- | unfused
enumFromToC :: (Eq a, Monad m, Enum a) => a -> a -> Producer m a
enumFromToC x0 y =
    loop x0
  where
    loop x
        | x == y = yield x
        | otherwise = yield x >> loop (succ x)
{-# INLINE enumFromToC #-}

-- | unfused
mapC :: Monad m => (a -> b) -> Conduit a m b
mapC f = awaitForever $ yield . f
{-# INLINE mapC #-}

-- | unfused
foldC :: Monad m => (b -> a -> b) -> b -> Consumer a m b
foldC f =
    loop
  where
    loop !b = await >>= maybe (return b) (loop . f b)
{-# INLINE foldC #-}

main :: IO ()
main = defaultMain
    [ bench "low level" $ flip whnf upper0 $ \upper ->
        let loop x t
                | x > upper = t
                | otherwise = loop (x + 1) (t + ((x * 2) + 1))
         in loop 1 0
    , bench "completely fused" $ flip whnf upper0 $ \upper ->
        runIdentity
            $ CL.enumFromTo 1 upper
           $$ (CL.map $ (* 2))
           =$ CL.map (+ 1)
           =$ CL.fold (+) 0
    -- , bench "completely unfused" $ flip whnf upper0 $ \upper ->
    --     runIdentity
    --         $ enumFromToC 1 upper
    --        $$ mapC (* 2)
    --        =$ mapC (+ 1)
    --        =$ foldC (+) 0
    -- , bench "beginning fusion" $ flip whnf upper0 $ \upper ->
    --     runIdentity
    --         $ (CL.enumFromTo 1 upper $= CL.map (* 2))
    --        $$ mapC (+ 1)
    --        =$ foldC (+) 0
    -- , bench "middle fusion" $ flip whnf upper0 $ \upper ->
    --     runIdentity
    --         $ enumFromToC 1 upper
    --        $$ (CL.map (* 2) =$= CL.map (+ 1))
    --        =$ foldC (+) 0
    -- , bench "ending fusion" $ flip whnf upper0 $ \upper ->
    --     runIdentity
    --         $ enumFromToC 1 upper
    --        $= mapC (* 2)
    --        $$ (CL.map (+ 1) =$ CL.fold (+) 0)
    -- , bench "performance of CL.enumFromTo without fusion" $ flip whnf upper0 $ \upper ->
    --     runIdentity
    --         $ CL.enumFromTo 1 upper
    --        $= mapC (* 2)
    --        $$ (CL.map (+ 1) =$ CL.fold (+) 0)
    ]
  where
    upper0 = 100000 :: Int
