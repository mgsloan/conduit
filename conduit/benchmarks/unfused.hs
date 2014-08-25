{-# LANGUAGE RankNTypes, BangPatterns, GADTs #-}
-- Compare low-level, fused, unfused, and partially fused
-- import Data.Conduit
import qualified Data.Conduit as C
import           Data.Conduit hiding (($$), (=$=), (=$), ($=))
import qualified Data.Conduit.List as CL
import           Data.Conduit.List (ConduitM'(..), Producer', Consumer', Conduit', ConduitStream(..))
import           Data.Conduit.Internal (Step (..), Stream (..), unstream, StreamConduit (..), ConduitM(..))
import           Criterion.Main
import           Data.Functor.Identity (runIdentity)
import           Control.Applicative
import           Data.Void
import           Debug.Trace
import           Control.Monad.Identity
import           Data.Conduit.Internal.Pipe (Pipe (..))

infixr 0 $$
infixl 1 $=
infixr 2 =$
infixr 2 =$=

instance Monad m => Monad (ConduitM' i o m) where
    return x = ConduitM' (return x) (ConduitStream (\_ -> Stream (\() -> return (Stop x)) (return ())))
    {-# INLINE return #-}
    l >>= r = ConduitM' (getConduitM l >>= (getConduitM . r)) NoStream
    {-# INLINE (>>=) #-}

connectStream1 :: Monad m
                 => Stream m i ()
                 -> ConduitM i Void m r
                 -> m r
connectStream1 fstream (ConduitM sink0) =
    case fstream of
        Stream step ms0 ->
            let loop _ (Done r) _ = return r
                loop ls (PipeM mp) s = mp >>= flip (loop ls) s
                loop ls (Leftover p l) s = loop (l:ls) p s
                loop _ (HaveOutput _ _ o) _ = absurd o
                loop (l:ls) (NeedInput p _) s = loop ls (p l) s
                loop [] (NeedInput p c) s = do
                    res <- step s
                    case res of
                        Stop () -> loop [] (c ()) s
                        Skip s' -> loop [] (NeedInput p c) s'
                        Emit s' i -> loop [] (p i) s'
             in ms0 >>= loop [] (sink0 Done)
{-# INLINE connectStream1 #-}

streamSource
    :: Monad m
    => Stream m o ()
    -> ConduitM i o m ()
streamSource str@(Stream step ms0) =
    ConduitM $ \rest -> PipeM $ do
        s0 <- ms0
        let loop s = do
                res <- step s
                case res of
                    Stop () -> return $ rest ()
                    Emit s' o -> return $ HaveOutput (PipeM $ loop s') (return ()) o
                    Skip s' -> loop s'
        loop s0
{-# INLINE streamSource #-}

streamSourcePure
    :: Monad m
    => Stream Identity o ()
    -> ConduitM i o m ()
streamSourcePure (Stream step ms0) =
    ConduitM $ \rest ->
        let loop s =
                case runIdentity $ step s of
                    Stop () -> rest ()
                    Emit s' o -> HaveOutput (loop s') (return ()) o
                    Skip s' -> loop s'
         in loop s0
  where
    s0 = runIdentity ms0
{-# INLINE streamSourcePure #-}

connectStream :: Monad m
                => Stream m o ()
                -> (Stream m o () -> Stream m Void r)
                -> m r
connectStream stream f = runStream $ f stream
{-# INLINE connectStream #-}

emptyStream :: Monad m => Stream m () ()
emptyStream = Stream emptyStep (return ())
  where
    emptyStep _ = return $ Stop ()
{-# INLINE emptyStream #-}

runStream (Stream step ms0) =
    ms0 >>= loop
  where
    loop s = do
        res <- step s
        case res of
            Stop r -> return r
            Skip s' -> loop s'
            Emit _ o -> absurd o
{-# INLINE runStream #-}

identityStream :: Monad m => Stream Identity o r -> Stream m o r
identityStream (Stream step s0) =
    Stream (return . runIdentity . step) (return (runIdentity s0))
{-# INLINE identityStream #-}

($$) :: Monad m => CL.Source' m a -> CL.Sink' a m b -> m b
ConduitM' l lcs $$ ConduitM' r rcs =
    case (lcs, rcs) of
--        (_               , StreamSource   _) -> return ()
--        (_               , IdentSource    _) -> return ()
        (NoStream        , NoStream        ) -> l C.$$ r
        --TODO: Consider bringing back "connectStream2"?
        (NoStream        , ConduitStream  _) -> l C.$$ r
        (ConduitStream ls, NoStream        ) -> ls emptyStream `connectStream1` r
        (ConduitStream ls, ConduitStream rs) -> ls emptyStream `connectStream` rs
        -- (StreamSource  ls, NoStream        ) -> ls `connectStream1` r
        -- (StreamSource  ls, ConduitStream rs) -> ls `connectStream` rs
        -- (IdentSource   ls, NoStream        ) -> identityStream ls `connectStream1` r
        -- (IdentSource   ls, ConduitStream rs) -> identityStream ls `connectStream` rs
{-# INLINE ($$) #-}

(=$=) :: Monad m => Conduit' a m b -> ConduitM' b c m r -> ConduitM' a c m r
ConduitM' l lcs =$= ConduitM' r rcs =
    case (lcs, rcs) of
--        (_               , StreamSource   _) -> undefined
--        (_               , IdentSource    _) -> undefined
        (NoStream        , NoStream        ) -> ConduitM' (l C.=$= r)                   NoStream
        --TODO: Can this be done such that it yields a stream?
        (NoStream        , ConduitStream  _) -> ConduitM' (l C.=$= r)                   NoStream
        (ConduitStream ls, NoStream        ) -> ConduitM' (l C.=$= r)                   NoStream
        (ConduitStream ls, ConduitStream rs) -> ConduitM' (l C.=$= r)                   (ConduitStream (rs . ls))
--        (StreamSource  ls, NoStream        ) -> ConduitM' (streamSource ls C.=$= r)     NoStream
--        (StreamSource  ls, ConduitStream rs) -> ConduitM' (streamSource ls C.=$= r)     (ConduitStream (\_ -> rs ls))
--        (IdentSource   ls, NoStream        ) -> ConduitM' (streamSourcePure ls C.=$= r) NoStream
--        (IdentSource   ls, ConduitStream rs) -> ConduitM' (streamSourcePure ls C.=$= r) (ConduitStream (\_ -> rs (identityStream ls)))
{-# inline (=$=) #-}

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

-- | unfused, using ConduitM'
enumFromToC' :: (Eq a, Monad m, Enum a) => a -> a -> Producer' m a
enumFromToC' x0 y =
    loop x0
  where
    loop x
        | x == y = ConduitM' (yield x) NoStream
        | otherwise = ConduitM' (yield x) NoStream >> loop (succ x)
{-# INLINE enumFromToC' #-}

-- | unfused, using ConduitM'
mapC' :: Monad m => (a -> b) -> Conduit' a m b
mapC' f = do
    mval <- ConduitM' await NoStream
    case mval of
        Just x -> do
            ConduitM' (yield (f x)) NoStream
            mapC' f
        Nothing -> return ()
{-# INLINE mapC' #-}

-- | unfused, using ConduitM'
foldC' :: Monad m => (b -> a -> b) -> b -> Consumer' a m b
foldC' f =
    loop
  where
    loop !b = (ConduitM' await NoStream) >>= maybe (return b) (loop . f b)
{-# INLINE foldC' #-}

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
    , bench "completely unfused" $ flip whnf upper0 $ \upper ->
        runIdentity
            $ enumFromToC 1 upper
           C.$$ foldC (+) 0
    , bench "completely unfused, ConduitM' overhead" $ flip whnf upper0 $ \upper ->
        runIdentity
            $ enumFromToC' 1 upper
           $$ foldC' (+) 0
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
