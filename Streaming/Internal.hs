{-# LANGUAGE LambdaCase, RankNTypes, EmptyCase,
             StandaloneDeriving, FlexibleContexts,
             DeriveDataTypeable, DeriveFoldable,
             DeriveFunctor, DeriveTraversable,
             ScopedTypeVariables, BangPatterns #-}
{-# LANGUAGE UndecidableInstances #-} -- for Streaming show instance
module Streaming.Internal where

import Control.Monad
import Control.Monad.Trans
import Control.Monad.Trans.Class
import Control.Applicative
import Data.Data ( Data, Typeable )
import Data.Foldable ( Foldable )
import Data.Traversable
import Control.Monad.Morph
import Data.Monoid
import Data.Functor.Identity
import GHC.Exts ( build )
import Prelude hiding (splitAt)

-- | A left-strict pair; the base functor for streams of individual elements.
data Of a b = !a :> b
    deriving (Data, Eq, Foldable, Functor, Ord,
              Read, Show, Traversable, Typeable)
infixr 4 :>

-- | Curry a function of left-strict pairs
kurry :: (Of a b -> c) -> a -> b -> c
kurry f = \a b -> f (a :> b)
{-# INLINE kurry #-}

-- | Uncurry a function into a function on left-strict pairs 

unkurry :: (a -> b -> c) -> Of a b -> c
unkurry f = \(a :> b) -> f a b
{-# INLINE unkurry #-}

-- | @Stream@ (\'FreeT\') data type. The constructors are exported by @Streaming.Internal@
data Stream f m r = Step !(f (Stream f m r))
                  | Delay (m (Stream f m r))
                  | Return r
                  deriving (Typeable)

deriving instance (Show r, Show (m (Stream f m r))
                  , Show (f (Stream f m r))) => Show (Stream f m r)
deriving instance (Eq r, Eq (m (Stream f m r))
                  , Eq (f (Stream f m r))) => Eq (Stream f m r)
deriving instance (Typeable f, Typeable m, Data r, Data (m (Stream f m r))
                  , Data (f (Stream f m r))) => Data (Stream f m r)

instance (Functor f, Monad m) => Functor (Stream f m) where
  fmap f = loop where
    loop stream = case stream of
      Return r -> Return (f r)
      Delay m  -> Delay (liftM loop m)
      Step f   -> Step (fmap loop f)
  {-# INLINABLE fmap #-}
  
instance (Functor f, Monad m) => Monad (Stream f m) where
  return = Return
  {-# INLINE return #-}
  stream1 >> stream2 = loop stream1 where
    loop stream = case stream of
      Return _ -> stream2
      Delay m  -> Delay (liftM loop m)
      Step f   -> Step (fmap loop f)    
  {-# INLINABLE (>>) #-}                              
  stream >>= f = loop stream where
    loop stream0 = case stream0 of
      Step f -> Step (fmap loop f)
      Delay m      -> Delay (liftM loop m)
      Return r      -> f r
  {-# INLINABLE (>>=) #-}                              

instance (Functor f, Monad m) => Applicative (Stream f m) where
  pure = Return
  {-# INLINE pure #-}
  streamf <*> streamx = do {f <- streamf; x <- streamx; return (f x)}   
  {-# INLINABLE (<*>) #-}    
  
instance Functor f => MonadTrans (Stream f) where
  lift = Delay . liftM Return
  {-# INLINE lift #-}

instance Functor f => MFunctor (Stream f) where
  hoist trans = loop where
    loop stream = case stream of 
      Return r  -> Return r
      Delay m   -> Delay (trans (liftM loop m))
      Step f    -> Step (fmap loop f)
  {-# INLINABLE hoist #-}    

instance (MonadIO m, Functor f) => MonadIO (Stream f m) where
  liftIO = Delay . liftM Return . liftIO
  {-# INLINE liftIO #-}

-- | Map a stream to its church encoding; compare list 'foldr'
destroy 
  :: (Functor f, Monad m) =>
     Stream f m r -> (f b -> b) -> (m b -> b) -> (r -> b) -> b
destroy stream0 construct wrap done = loop stream0 where
  loop stream = case stream of
    Return r -> done r
    Delay m  -> wrap (liftM loop m)
    Step fs  -> construct (fmap loop fs)
{-# INLINABLE destroy #-}

-- | Reflect a church-encoded stream; cp. GHC.Exts.build
construct
  :: (forall b . (f b -> b) -> (m b -> b) -> (r -> b) -> b) ->  Stream f m r
construct = \phi -> phi Step Delay Return
{-# INLINE construct #-}

-- | Map layers of one functor to another with a natural transformation
maps :: (Monad m, Functor f) => (forall x . f x -> g x) -> Stream f m r -> Stream g m r
maps phi = loop where
  loop stream = case stream of 
    Return r  -> Return r
    Delay m   -> Delay (liftM loop m)
    Step f    -> Step (phi (fmap loop f))
{-# INLINABLE maps #-}

mapsM :: (Monad m, Functor f) => (forall x . f x -> m (g x)) -> Stream f m r -> Stream g m r
mapsM phi = loop where
  loop stream = case stream of 
    Return r  -> Return r
    Delay m   -> Delay (liftM loop m)
    Step f    -> Delay (liftM Step (phi (fmap loop f)))
{-# INLINABLE mapsM #-}

maps' :: (Monad m, Functor f) 
          => (forall x . f x -> m (a, x)) 
          -> Stream f m r 
          -> Stream (Of a) m r
maps' phi = loop where
  loop stream = case stream of 
    Return r -> Return r
    Delay m -> Delay $ liftM loop m
    Step fs -> Delay $ liftM (Step . uncurry (:>)) (phi (fmap loop fs))
{-# INLINABLE maps' #-}

intercalates :: (Monad m, Monad (t m), MonadTrans t) =>
     t m a -> Stream (t m) m b -> t m b
intercalates sep = go0
  where
    go0 f = case f of 
      Return r -> return r 
      Delay m -> lift m >>= go0 
      Step fstr -> do
                f' <- fstr
                go1 f'
    go1 f = case f of 
      Return r -> return r 
      Delay m     -> lift m >>= go1
      Step fstr ->  do
                sep
                f' <- fstr
                go1 f'
{-# INLINABLE intercalates #-}

intercalates' :: (Monad m, Monad (t m), MonadTrans t) =>
     t m a -> Stream (t m) m b -> t m b
intercalates' sep stream = destroy stream 
   (\tmstr -> do 
     str <- tmstr
     sep
     str
     )
   (join . lift)
   return
{-# INLINE intercalates' #-}

iterTM ::
  (Functor f, Monad m, MonadTrans t,
   Monad (t m)) =>
  (f (t m a) -> t m a) -> Stream f m a -> t m a
iterTM out stream = destroy stream out (join . lift) return
{-# INLINE iterTM #-}

iterT ::
  (Functor f, Monad m) => (f (m a) -> m a) -> Stream f m a -> m a
iterT out stream = destroy stream out join return
{-# INLINE iterT #-}

concats ::
    (MonadTrans t, Monad (t m), Monad m) =>
    Stream (t m) m a -> t m a
concats stream = destroy stream join (join . lift) return
{-# INLINE concats #-}


splitAt :: (Monad m, Functor f) => Int -> Stream f m r -> Stream f m (Stream f m r)
splitAt = loop where
  loop !n stream 
    | n <= 1 = Return stream
    | otherwise = case stream of
        Return r       -> Return (Return r)
        Delay m        -> Delay (liftM (loop n) m)
        Step fs        -> case n of 
          0 -> Return (Step fs)
          _ -> Step (fmap (loop (n-1)) fs)
{-# INLINABLE splitAt #-}                        

chunksOf :: (Monad m, Functor f) => Int -> Stream f m r -> Stream (Stream f m) m r
chunksOf n0 = loop where
  loop stream = case stream of
    Return r       -> Return r
    Delay m        -> Delay (liftM loop m)
    Step fs        -> Step $ Step $ fmap (fmap loop . splitAt n0) fs
{-# INLINABLE chunksOf #-}          





-- church encodings:
-- ----- unwrapped synonym:
type Folding_ f m r = forall r'
                   .  (f r' -> r')
                   -> (m r' -> r')
                   -> (r -> r')
                   -> r'
-- ------ wrapped:
newtype Folding f m r = Folding {getFolding :: Folding_ f m r  }

-- these should perhaps be expressed with
-- predefined combinators for Folding_
instance Functor (Folding f m) where
  fmap f phi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (done . f))

instance Monad (Folding f m) where
  return r = Folding (\construct wrap done -> done r)
  (>>=) = flip foldBind
  {-# INLINE (>>=) #-}

foldBind f phi = Folding (\construct wrap done ->
  getFolding phi construct
              wrap
              (\a -> getFolding (f a) construct
                                   wrap
                                   done))
{-# INLINE foldBind #-}

instance Applicative (Folding f m) where
  pure r = Folding (\construct wrap done -> done r)
  phi <*> psi = Folding (\construct wrap done ->
    getFolding phi construct
                wrap
                (\f -> getFolding psi construct
                                   wrap
                                   (\a -> done (f a))))

instance MonadTrans (Folding f) where
  lift ma = Folding (\constr wrap done -> wrap (liftM done ma))
  {-# INLINE lift #-}
  
instance Functor f => MFunctor (Folding f) where
  hoist trans phi = Folding (\construct wrap done ->
    getFolding phi construct (wrap . trans) done)
  {-# INLINE hoist #-}
instance (MonadIO m, Functor f) => MonadIO (Folding f m) where
  liftIO io = Folding (\construct wrap done ->
             wrap (liftM done (liftIO io))
                )
  {-# INLINE liftIO #-}


mapsF :: (forall x . f x -> g x) -> Folding f m r -> Folding g m r
mapsF morph (Folding phi) = Folding $ \construct wrap done -> 
    phi (construct . morph)
        wrap
        done
{-# INLINE mapsF #-}

mapsMF :: (Monad m) => (forall x . f x -> m (g x)) -> Folding f m r -> Folding g m r
mapsMF morph (Folding phi) = Folding $ \construct wrap done -> 
    phi (wrap . liftM construct . morph)
        wrap
        done
{-# INLINE mapsMF #-}


mapsFoldF :: (Monad m) 
          => (forall x . f x -> m (a, x)) 
          -> Folding f m r 
          -> Folding (Of a) m r
mapsFoldF crush = mapsMF (liftM (\(a,b) -> a :> b) . crush) 
{-# INLINE mapsFoldF #-}

-- -------------------------------------
-- optimization operations: wrapped case
-- -------------------------------------

--

-- `foldStream` is a flipped and wrapped variant of Atkey's
-- effectfulFolding :: (Functor f, Monad m) =>
--    (m x -> x) -> (r -> x) -> (f x -> x) -> Stream f m r -> x
-- modulo the 'Return' constructor, which implicitly restricts the
-- available class of Functors.
-- See http://bentnib.org/posts/2012-01-06-streams.html and
-- the (nightmarish) associated paper.

-- Our plan is thus where possible to replace the datatype Stream with
-- the associated effectfulFolding itself, wrapped as Folding

foldStream  :: (Functor f, Monad m) => Stream f m t -> Folding f m t
foldStream lst = Folding (destroy lst)
{-# INLINE[0] foldStream  #-}

buildStream :: Folding f m r -> Stream f m r
buildStream (Folding phi) = phi Step Delay Return
{-# INLINE[0] buildStream #-}


-- The compiler has no difficulty with the rule for the wrapped case.
-- I have not investigated whether the remaining newtype
-- constructor is acting as an impediment. The stage [0] or [1]
-- seems irrelevant in either case.

{-# RULES
  "foldStream/buildStream" forall phi.
    foldStream (buildStream phi) = phi
    #-}

-- -------------------------------------
-- optimization operations: unwrapped case
-- -------------------------------------


foldStreamx
  :: (Functor f, Monad m) =>
     Stream f m t -> (f b -> b) -> (m b -> b) -> (t -> b) -> b
foldStreamx = \lst construct wrap done ->
   let loop = \case Delay mlst -> wrap (liftM loop mlst)
                    Step flst  -> construct (fmap loop flst)
                    Return r   -> done r
   in  loop lst
{-# INLINE[1] foldStreamx #-}


buildStreamx = \phi -> phi Step Delay Return
{-# INLINE[1] buildStreamx #-}

-- The compiler seems to have trouble seeing these rules as applicable,
-- unlike those for foldStream & buildStream. Opaque arity is
-- a plausible hypothesis when you know nothing yet.
-- When additional arguments are given to a rule,
-- the most saturated is the one that fires,
-- but it only fires where this one would.

{-# RULES

  "foldStreamx/buildStreamx" forall phi.
    foldStreamx (buildStreamx phi) = phi

    #-}


buildList_ :: Folding_ (Of a) Identity () -> [a]
buildList_ phi = phi (\(a :> as) -> a : as)
                     (\(Identity xs) -> xs)
                     (\() -> [])
{-# INLINE buildList_ #-}

buildListM_ :: Monad m => Folding_ (Of a) m () -> m [a]
buildListM_ phi = phi (\(a :> mas) -> liftM (a :) mas)
                      (>>= id)
                      (\() -> return [])
{-# INLINE buildListM_ #-}

foldList_ :: Monad m => [a] -> Folding_ (Of a) m ()
foldList_ xs = \construct wrap done ->
           foldr (\x r -> construct (x:>r)) (done ()) xs
{-# INLINE foldList_ #-}


buildList :: Folding (Of a) Identity () -> [a]
buildList = \(Folding phi) -> buildList_ phi
{-# INLINE[0] buildList #-}

foldList :: Monad m => [a] -> Folding (Of a) m ()
foldList = \xs -> Folding (foldList_ xs)
{-# INLINE[0] foldList #-}

{-# RULES
  "foldr/buildList" forall phi op seed .
    foldr op seed (buildList phi) =
       getFolding phi (unkurry op) runIdentity (\() -> seed)
    #-}
    
{-# RULES
  "foldr/buildList_" forall (phi :: Folding_ (Of a) Identity ()) 
                            (op :: a -> b -> b) 
                            (seed :: b) .
    foldr op seed (buildList_ phi) =
       phi (unkurry op) runIdentity (\() -> seed)
    #-}

{-# RULES
  "foldList/buildList" forall phi.
    foldList(buildList phi) = phi
    #-}               
    
              
