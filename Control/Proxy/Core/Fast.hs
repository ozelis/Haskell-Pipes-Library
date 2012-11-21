{-# LANGUAGE Rank2Types #-}

{-| A 'Proxy' 'request's input from upstream and 'respond's with output to
    downstream.

    For an extended tutorial, consult "Control.Proxy.Tutorial". -}

module Control.Proxy.Core.Fast (
    -- * Types
    Proxy(..),

    -- * Run Sessions 
    -- $run
    runProxy,
    runProxyK,
    runSession,
    runSessionK,

    -- * Utility Proxies
    -- $utility
    discard,
    ignore,

    -- * Pipe compatibility
    runPipe
    ) where

import Control.Applicative (Applicative(pure, (<*>)))
import Control.Monad (ap, forever, liftM, (>=>))
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Trans.Class (MonadTrans(lift))
import Control.MFunctor (MFunctor(mapT))
import Control.Proxy.Class
import Control.Proxy.Synonym (Pipeline, Server, Client)
import Data.Closed (C)

{-| A 'Proxy' communicates with an upstream interface and a downstream
    interface.

    The type variables of @Proxy req_a resp_a req_b resp_b m r@ signify:

    * @req_a @ - The request supplied to the upstream interface

    * @resp_a@ - The response provided by the upstream interface

    * @req_b @ - The request supplied by the downstream interface

    * @resp_b@ - The response provided to the downstream interface

    * @m     @ - The base monad

    * @r     @ - The final return value -}
data Proxy a' a b' b m r
  = Request a' (a  -> Proxy a' a b' b m r )
  | Respond b  (b' -> Proxy a' a b' b m r )
  | M          (m    (Proxy a' a b' b m r))
  | Pure r

instance (Monad m) => Functor (Proxy a' a b' b m) where
    fmap f p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       r   -> Pure (f r)

instance (Monad m) => Applicative (Proxy a' a b' b m) where
    pure      = Pure
    pf <*> px = go pf where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       f   -> fmap f px

instance (Monad m) => Monad (Proxy a' a b' b m) where
    return   = Pure
    p0 >>= f = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       r   -> f r

instance MonadTrans (Proxy a' a b' b) where
    lift = _lift

_lift :: (Monad m) => m r -> Proxy a' a b' b m r
_lift m = M (m >>= \r -> return (Pure r))
-- _lift = M . liftM Pure

{- These never fire, for some reason, but keep them until I figure out how to
   get them to work. -}
{-# RULES
    "_lift m >>= f" forall m f . _lift m >>= f = M (m >>= \r -> return (f r))
  ; "_lift m ?>= f" forall m f . _lift m ?>= f = M (m >>= \r -> return (f r))
  #-}

instance (MonadIO m) => MonadIO (Proxy a' a b' b m) where
    liftIO m = M (liftIO (m >>= \r -> return (Pure r)))
 -- liftIO = M . liftIO . liftM Pure

instance MonadIOP Proxy where
    liftIO_P = liftIO

instance ProxyP Proxy where
    idT = \a' -> Request a' (\a -> Respond a idT)
    k1 <-< k2_0 = \c' -> k1 c' |-< k2_0 where
        p1 |-< k2 = case p1 of
            Request b' fb  -> fb <-| k2 b'
            Respond c  fc' -> Respond c (\c' -> fc' c' |-< k2)
            M          m   -> M (m >>= \p1' -> return (p1' |-< k2))
            Pure       r   -> Pure r
        fb <-| p2 = case p2 of
            Request a' fa  -> Request a' (\a -> fb <-| fa a) 
            Respond b  fb' -> fb b |-< fb'
            M          m   -> M (m >>= \p2' -> return (fb <-| p2'))
            Pure       r   -> Pure r

    {- For some reason, these must be defined in separate functions for the
       RULES to fire. -}
    request = _request
    respond = _respond

    return_P = return
    (?>=)   = (>>=)

    lift_P = _lift

_request :: (Monad m) => a' -> Proxy a' a b' b m a
_request = \a' -> Request a' Pure

_respond :: (Monad m) => b -> Proxy a' a b' b m b'
_respond = \b  -> Respond b  Pure

{-# RULES
    "_request a' >>= f" forall a' f . _request a' >>= f = Request a' f
  ; "_respond b  >>= f" forall b  f . _respond b  >>= f = Respond b  f
  ; "_request a' ?>= f" forall a' f . _request a' ?>= f = Request a' f
  ; "_respond b  ?>= f" forall b  f . _respond b  ?>= f = Respond b  f
  #-}

instance InteractP Proxy where
    k1 /</ k2 = \a' -> go (k1 a') where
        go p = case p of
            Request b' fb  -> k2 b' >>= \b -> go (fb b)
            Respond x  fx' -> Respond x (\x' -> go (fx' x'))
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a
    k1 \<\ k2 = \a' -> go (k2 a') where
        go p = case p of
            Request x' fx  -> Request x' (\x -> go (fx x))
            Respond b  fb' -> k1 b >>= \b' -> go (fb' b')
            M          m   -> M (m >>= \p' -> return (go p'))
            Pure       a   -> Pure a

instance MFunctor (Proxy a' a b' b) where
    mapT nat p0 = go p0 where
        go p = case p of
            Request a' fa  -> Request a' (\a  -> go (fa  a ))
            Respond b  fb' -> Respond b  (\b' -> go (fb' b'))
            M          m   -> M (nat (m >>= \p' -> return (go p')))
            Pure       r   -> Pure r

instance MFunctorP Proxy where
    mapT_P = mapT

{- $run
    I provide two ways to run proxies:

    * 'runProxy', which discards unhandled output from either end

    * 'runSession', which type restricts its argument to ensure no loose ends

    Both functions require that the input to each end is trivially satisfiable,
    (i.e. @()@).

    I recommend 'runProxy' for most use cases since it is more convenient.

    'runSession' only accepts sessions that do not send unhandled data flying
    off each end, which provides the following benefits:

    * It prevents against accidental data loss.

    * It protects against silent failures

    * It prevents wastefully draining a scarce resource by gratuitously
      driving it to completion

    However, this restriction means that you must either duplicate every utility
    function to specialize them to the end-point positions (which I do not do),
    or explicitly close loose ends using the 'discard' and 'ignore' proxies:

> runSession $ discard <-< p <-< ignore

    Use the \'@K@\' versions of each command if you are running sessions nested
    within sessions.  They provide a Kleisli arrow as their result suitable to
    be passed to another 'runProxy' / 'runSession' command.
-}

{-| Run a self-sufficient 'Proxy' Kleisli arrow, converting it back to the base
    monad -}
runProxy :: (Monad m) => (() -> Proxy a' () () b m r) -> m r
runProxy k = go (k ()) where
    go p = case p of
        Request _ fa  -> go (fa  ())
        Respond _ fb' -> go (fb' ())
        M         m   -> m >>= go
        Pure      r   -> return r

{-| Run a self-sufficient 'Proxy' Kleisli arrow, converting it back to a Kleisli
    arrow in the base monad -}
runProxyK :: (Monad m) => (() -> Proxy a' () () b m r) -> (() -> m r)
runProxyK p = \() -> runProxy p

{-| Run a self-contained 'Session' Kleisli arrow, converting it back to the base
    monad -}
runSession :: (Monad m) => (() -> Proxy C () () C m r) -> m r
runSession = runProxy

{-| Run a self-contained 'Session' Kleisli arrow, converting it back to a
    Kleisli arrow in the base monad -}
runSessionK :: (Monad m) => (() -> Proxy C () () C m r) -> (() -> m r)
runSessionK = runProxyK

{- $utility
    'discard' provides a fallback client that gratuitously 'request's input
    from a server, but discards all responses.

    'ignore' provides a fallback server that trivially 'respond's with output
    to a client, but ignores all request parameters.
-}

-- | Discard all responses
discard :: (Monad m) => () -> Proxy () a () C m r
discard _ = go where
    go = Request () (\_ -> go)

-- | Ignore all requests
ignore  :: (Monad m) => a -> Proxy C () a () m r
ignore _ = go where
    go = Respond () (\_ -> go)

-- | Run the 'Pipe' monad transformer, converting it back to the base monad
runPipe :: (Monad m) => Pipeline Proxy m r -> m r
runPipe p' = go p' where
    go p = case p of
        Request _ fa  -> go (fa  ())
        Respond _ fb' -> go (fb' ())
        M         m   -> m >>= go
        Pure      r   -> return r