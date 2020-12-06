{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Runtime.Machine where

import Control.Concurrent (ThreadId, forkIOWithUnmask)
import Control.Concurrent.STM as STM
import Control.Exception
import Control.Lens ((<&>))
import Data.Bits
import Data.Foldable (toList)
import qualified Data.Map.Strict as M
import Data.Maybe (fromMaybe)
import qualified Data.Primitive.PrimArray as PA
import qualified Data.Sequence as Sq
import qualified Data.Set as S
import qualified Data.Text as Tx
import qualified Data.Text.IO as Tx
import Data.Traversable
import Data.Word (Word64)
import GHC.Stack
import Text.Read (readMaybe)
import Unison.Reference (Reference (Builtin))
import Unison.Referent (pattern Ref)
import Unison.Runtime.ANF as ANF
  ( Mem (..),
    SuperGroup,
    groupLinks,
    valueLinks,
  )
import qualified Unison.Runtime.ANF as ANF
import Unison.Runtime.Builtin
import Unison.Runtime.Exception
import Unison.Runtime.Foreign
import Unison.Runtime.Foreign.Function
import qualified Unison.Runtime.IOSource as Rf
import Unison.Runtime.MCode
import Unison.Runtime.Stack
import Unison.Symbol (Symbol)
import qualified Unison.Type as Rf
import qualified Unison.Util.Bytes as By
import Unison.Util.EnumContainers as EC
import qualified Unison.Util.Pretty as Pr

type Tag = Word64

-- dynamic environment
type DEnv = EnumMap Word64 Closure

-- code caching environment
data CCache = CCache
  { foreignFuncs :: EnumMap Word64 ForeignFunc,
    combs :: TVar (EnumMap Word64 Combs),
    combRefs :: TVar (EnumMap Word64 Reference),
    tagRefs :: TVar (EnumMap Word64 Reference),
    freshTm :: TVar Word64,
    freshTy :: TVar Word64,
    intermed :: TVar (M.Map Reference (SuperGroup Symbol)),
    refTm :: TVar (M.Map Reference Word64),
    refTy :: TVar (M.Map Reference Word64)
  }

refNumsTm :: CCache -> IO (M.Map Reference Word64)
refNumsTm cc = readTVarIO (refTm cc)

refNumsTy :: CCache -> IO (M.Map Reference Word64)
refNumsTy cc = readTVarIO (refTy cc)

refNumTm :: CCache -> Reference -> IO Word64
refNumTm cc r =
  refNumsTm cc >>= \case
    (M.lookup r -> Just w) -> pure w
    _ -> die $ "refNumTm: unknown reference: " ++ show r

refNumTy :: CCache -> Reference -> IO Word64
refNumTy cc r =
  refNumsTy cc >>= \case
    (M.lookup r -> Just w) -> pure w
    _ -> die $ "refNumTy: unknown reference: " ++ show r

refNumTy' :: CCache -> Reference -> IO (Maybe Word64)
refNumTy' cc r = M.lookup r <$> refNumsTy cc

baseCCache :: IO CCache
baseCCache =
  CCache builtinForeigns
    <$> newTVarIO combs
    <*> newTVarIO builtinTermBackref
    <*> newTVarIO builtinTypeBackref
    <*> newTVarIO ftm
    <*> newTVarIO fty
    <*> newTVarIO mempty
    <*> newTVarIO builtinTermNumbering
    <*> newTVarIO builtinTypeNumbering
  where
    ftm = 1 + maximum builtinTermNumbering
    fty = 1 + maximum builtinTypeNumbering

    combs =
      mapWithKey
        (\k v -> emitComb @Symbol emptyRNs k mempty (0, v))
        numberedTermLookup

info :: Show a => String -> a -> IO ()
info ctx x = infos ctx (show x)

infos :: String -> String -> IO ()
infos ctx s = putStrLn $ ctx ++ ": " ++ s

-- Entry point for evaluating a section
eval0 :: CCache -> Section -> IO ()
eval0 !env !co = do
  ustk <- alloc
  bstk <- alloc
  eval env mempty ustk bstk KE co

-- Entry point for evaluating a numbered combinator.
-- An optional callback for the base of the stack may be supplied.
--
-- This is the entry point actually used in the interactive
-- environment currently.
apply0 ::
  Maybe (Stack 'UN -> Stack 'BX -> IO ()) ->
  CCache ->
  Word64 ->
  IO ()
apply0 !callback !env !i = do
  ustk <- alloc
  bstk <- alloc
  cmbrs <- readTVarIO $ combRefs env
  r <- case EC.lookup i cmbrs of
    Just r -> pure r
    Nothing -> die "apply0: missing reference to entry point"
  apply env mempty ustk bstk k0 True ZArgs $
    PAp (CIx r i 0) unull bnull
  where
    k0 = maybe KE (CB . Hook) callback

-- Apply helper currently used for forking. Creates the new stacks
-- necessary to evaluate a closure with the provided information.
apply1 ::
  (Stack 'UN -> Stack 'BX -> IO ()) ->
  CCache ->
  Closure ->
  IO ()
apply1 callback env clo = do
  ustk <- alloc
  bstk <- alloc
  apply env mempty ustk bstk k0 True ZArgs clo
  where
    k0 = CB $ Hook callback

lookupDenv :: Word64 -> DEnv -> Closure
lookupDenv p denv = fromMaybe BlackHole $ EC.lookup p denv

exec ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Instr ->
  IO (DEnv, Stack 'UN, Stack 'BX, K)
exec !_ !denv !ustk !bstk !k (Info tx) = do
  info tx ustk
  info tx bstk
  info tx k
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (Name r args) = do
  bstk <- name ustk bstk args =<< resolve env denv bstk r
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (SetDyn p i) = do
  clo <- peekOff bstk i
  pure (EC.mapInsert p clo denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Capture p) = do
  (sk, denv, ustk, bstk, useg, bseg, k) <- splitCont denv ustk bstk k p
  bstk <- bump bstk
  poke bstk $ Captured sk useg bseg
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (UPrim1 op i) = do
  ustk <- uprim1 ustk op i
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (UPrim2 op i j) = do
  ustk <- uprim2 ustk op i j
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (BPrim1 MISS i) = do
  clink <- peekOff bstk i
  let Ref link = unwrapForeign $ marshalToForeign clink
  m <- readTVarIO (intermed env)
  ustk <- bump ustk
  if (link `M.member` m) then poke ustk 1 else poke ustk 0
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (BPrim1 CACH i) = do
  arg <- peekOffS bstk i
  news <- decodeCacheArgument arg
  unknown <- cacheAdd news env
  bstk <- bump bstk
  pokeS
    bstk
    (Sq.fromList $ Foreign . Wrap Rf.typeLinkRef . Ref <$> unknown)
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (BPrim1 LKUP i) = do
  clink <- peekOff bstk i
  let Ref link = unwrapForeign $ marshalToForeign clink
  m <- readTVarIO (intermed env)
  ustk <- bump ustk
  bstk <- case M.lookup link m of
    Nothing -> bstk <$ poke ustk 0
    Just sg -> do
      poke ustk 1
      bstk <- bump bstk
      bstk <$ pokeBi bstk sg
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (BPrim1 LOAD i) = do
  v <- peekOffBi bstk i
  ustk <- bump ustk
  bstk <- bump bstk
  reifyValue env v >>= \case
    Left miss -> do
      poke ustk 0
      pokeS bstk $ Sq.fromList $ Foreign . Wrap Rf.termLinkRef <$> miss
    Right x -> do
      poke ustk 1
      poke bstk x
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (BPrim1 VALU i) = do
  m <- readTVarIO (tagRefs env)
  c <- peekOff bstk i
  bstk <- bump bstk
  pokeBi bstk =<< reflectValue m c
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (BPrim1 op i) = do
  (ustk, bstk) <- bprim1 ustk bstk op i
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (BPrim2 EQLU i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  ustk <- bump ustk
  poke ustk $
    case universalCompare compare x y of
      EQ -> 1
      _ -> 0
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (BPrim2 CMPU i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  ustk <- bump ustk
  poke ustk . fromEnum $ universalCompare compare x y
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (BPrim2 op i j) = do
  (ustk, bstk) <- bprim2 ustk bstk op i j
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Pack r t args) = do
  clo <- buildData ustk bstk r t args
  bstk <- bump bstk
  poke bstk clo
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Unpack i) = do
  (ustk, bstk) <- dumpData ustk bstk =<< peekOff bstk i
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Print i) = do
  t <- peekOffBi bstk i
  Tx.putStrLn t
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Lit (MI n)) = do
  ustk <- bump ustk
  poke ustk n
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Lit (MD d)) = do
  ustk <- bump ustk
  pokeD ustk d
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Lit (MT t)) = do
  bstk <- bump bstk
  poke bstk (Foreign (Wrap Rf.textRef t))
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Lit (MM r)) = do
  bstk <- bump bstk
  poke bstk (Foreign (Wrap Rf.termLinkRef r))
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Lit (MY r)) = do
  bstk <- bump bstk
  poke bstk (Foreign (Wrap Rf.typeLinkRef r))
  pure (denv, ustk, bstk, k)
exec !_ !denv !ustk !bstk !k (Reset ps) = do
  pure (denv, ustk, bstk, Mark ps clos k)
  where
    clos = EC.restrictKeys denv ps
exec !_ !denv !ustk !bstk !k (Seq as) = do
  l <- closureArgs bstk as
  bstk <- bump bstk
  pokeS bstk $ Sq.fromList l
  pure (denv, ustk, bstk, k)
exec !env !denv !ustk !bstk !k (ForeignCall _ w args)
  | Just (FF arg res ev) <- EC.lookup w (foreignFuncs env) =
    uncurry (denv,,,k)
      <$> (arg ustk bstk args >>= ev >>= res ustk bstk)
  | otherwise =
    die $ "reference to unknown foreign function: " ++ show w
exec !env !denv !ustk !bstk !k (Fork i) = do
  tid <- forkEval env =<< peekOff bstk i
  bstk <- bump bstk
  poke bstk . Foreign . Wrap Rf.threadIdReference $ tid
  pure (denv, ustk, bstk, k)
{-# INLINE exec #-}

eval ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Section ->
  IO ()
eval !env !denv !ustk !bstk !k (Match i (TestT df cs)) = do
  t <- peekOffBi bstk i
  eval env denv ustk bstk k $ selectTextBranch t df cs
eval !env !denv !ustk !bstk !k (Match i br) = do
  n <- peekOffN ustk i
  eval env denv ustk bstk k $ selectBranch n br
eval !env !denv !ustk !bstk !k (Yield args)
  | asize ustk + asize bstk > 0,
    BArg1 i <- args = do
    peekOff bstk i >>= apply env denv ustk bstk k False ZArgs
  | otherwise = do
    (ustk, bstk) <- moveArgs ustk bstk args
    ustk <- frameArgs ustk
    bstk <- frameArgs bstk
    yield env denv ustk bstk k
eval !env !denv !ustk !bstk !k (App ck r args) =
  resolve env denv bstk r
    >>= apply env denv ustk bstk k ck args
eval !env !denv !ustk !bstk !k (Call ck n args) =
  combSection env (CIx dummyRef n 0)
    >>= enter env denv ustk bstk k ck args
eval !env !denv !ustk !bstk !k (Jump i args) =
  peekOff bstk i >>= jump env denv ustk bstk k args
eval !env !denv !ustk !bstk !k (Let nw cix) = do
  (ustk, ufsz, uasz) <- saveFrame ustk
  (bstk, bfsz, basz) <- saveFrame bstk
  eval env denv ustk bstk (Push ufsz bfsz uasz basz cix k) nw
eval !env !denv !ustk !bstk !k (Ins i nx) = do
  (denv, ustk, bstk, k) <- exec env denv ustk bstk k i
  eval env denv ustk bstk k nx
eval !_ !_ !_ !_ !_ Exit = pure ()
eval !_ !_ !_ !_ !_ (Die s) = die s
{-# NOINLINE eval #-}

forkEval :: CCache -> Closure -> IO ThreadId
forkEval env clo =
  forkIOWithUnmask $ \unmask ->
    unmask (apply1 err env clo) `catch` \case
      PE e ->
        putStrLn "runtime exception"
          >> print (Pr.render 70 e)
      BU _ -> putStrLn $ "unison exception reached top level"
  where
    err :: Stack 'UN -> Stack 'BX -> IO ()
    err _ bstk =
      peek bstk >>= \case
        -- Left e
        DataB1 _ 0 e -> throwIO $ BU e
        _ -> pure ()
{-# INLINE forkEval #-}

-- fast path application
enter ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Bool ->
  Args ->
  Comb ->
  IO ()
enter !env !denv !ustk !bstk !k !ck !args !comb = do
  ustk <- if ck then ensure ustk uf else pure ustk
  bstk <- if ck then ensure bstk bf else pure bstk
  (ustk, bstk) <- moveArgs ustk bstk args
  ustk <- acceptArgs ustk ua
  bstk <- acceptArgs bstk ba
  eval env denv ustk bstk k entry
  where
    Lam ua ba uf bf entry = comb
{-# INLINE enter #-}

-- fast path by-name delaying
name :: Stack 'UN -> Stack 'BX -> Args -> Closure -> IO (Stack 'BX)
name !ustk !bstk !args clo = case clo of
  PAp comb useg bseg -> do
    (useg, bseg) <- closeArgs I ustk bstk useg bseg args
    bstk <- bump bstk
    poke bstk $ PAp comb useg bseg
    pure bstk
  _ -> die $ "naming non-function: " ++ show clo
{-# INLINE name #-}

-- slow path application
apply ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Bool ->
  Args ->
  Closure ->
  IO ()
apply !env !denv !ustk !bstk !k !ck !args (PAp comb useg bseg) =
  combSection env comb >>= \case
    Lam ua ba uf bf entry
      | ck || ua <= uac && ba <= bac -> do
        ustk <- ensure ustk uf
        bstk <- ensure bstk bf
        (ustk, bstk) <- moveArgs ustk bstk args
        ustk <- dumpSeg ustk useg A
        bstk <- dumpSeg bstk bseg A
        ustk <- acceptArgs ustk ua
        bstk <- acceptArgs bstk ba
        eval env denv ustk bstk k entry
      | otherwise -> do
        (useg, bseg) <- closeArgs C ustk bstk useg bseg args
        ustk <- discardFrame =<< frameArgs ustk
        bstk <- discardFrame =<< frameArgs bstk
        bstk <- bump bstk
        poke bstk $ PAp comb useg bseg
        yield env denv ustk bstk k
  where
    uac = asize ustk + ucount args + uscount useg
    bac = asize bstk + bcount args + bscount bseg
apply !env !denv !ustk !bstk !k !_ !args clo
  | ZArgs <- args,
    asize ustk == 0,
    asize bstk == 0 = do
    ustk <- discardFrame ustk
    bstk <- discardFrame bstk
    bstk <- bump bstk
    poke bstk clo
    yield env denv ustk bstk k
  | otherwise = die $ "applying non-function: " ++ show clo
{-# INLINE apply #-}

jump ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Args ->
  Closure ->
  IO ()
jump !env !denv !ustk !bstk !k !args clo = case clo of
  Captured sk useg bseg -> do
    (useg, bseg) <- closeArgs K ustk bstk useg bseg args
    ustk <- discardFrame ustk
    bstk <- discardFrame bstk
    ustk <- dumpSeg ustk useg . F $ ucount args
    bstk <- dumpSeg bstk bseg . F $ bcount args
    repush env ustk bstk denv sk k
  _ -> die "jump: non-cont"
{-# INLINE jump #-}

repush ::
  CCache ->
  Stack 'UN ->
  Stack 'BX ->
  DEnv ->
  K ->
  K ->
  IO ()
repush !env !ustk !bstk = go
  where
    go !denv KE !k = yield env denv ustk bstk k
    go !denv (Mark ps cs sk) !k = go denv' sk $ Mark ps cs' k
      where
        denv' = cs <> EC.withoutKeys denv ps
        cs' = EC.restrictKeys denv ps
    go !denv (Push un bn ua ba nx sk) !k =
      go denv sk $ Push un bn ua ba nx k
    go !_ (CB _) !_ = die "repush: impossible"
{-# INLINE repush #-}

moveArgs ::
  Stack 'UN ->
  Stack 'BX ->
  Args ->
  IO (Stack 'UN, Stack 'BX)
moveArgs !ustk !bstk ZArgs = do
  ustk <- discardFrame ustk
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArgV i j) = do
  ustk <-
    if ul > 0
      then prepareArgs ustk (ArgR 0 ul)
      else discardFrame ustk
  bstk <-
    if bl > 0
      then prepareArgs bstk (ArgR 0 bl)
      else discardFrame bstk
  pure (ustk, bstk)
  where
    ul = fsize ustk - i
    bl = fsize bstk - j
moveArgs !ustk !bstk (UArg1 i) = do
  ustk <- prepareArgs ustk (Arg1 i)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArg2 i j) = do
  ustk <- prepareArgs ustk (Arg2 i j)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArgR i l) = do
  ustk <- prepareArgs ustk (ArgR i l)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArg1 i) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (Arg1 i)
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArg2 i j) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (Arg2 i j)
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArgR i l) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (ArgR i l)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArg2 i j) = do
  ustk <- prepareArgs ustk (Arg1 i)
  bstk <- prepareArgs bstk (Arg1 j)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArgR ui ul bi bl) = do
  ustk <- prepareArgs ustk (ArgR ui ul)
  bstk <- prepareArgs bstk (ArgR bi bl)
  pure (ustk, bstk)
moveArgs !ustk !bstk (UArgN as) = do
  ustk <- prepareArgs ustk (ArgN as)
  bstk <- discardFrame bstk
  pure (ustk, bstk)
moveArgs !ustk !bstk (BArgN as) = do
  ustk <- discardFrame ustk
  bstk <- prepareArgs bstk (ArgN as)
  pure (ustk, bstk)
moveArgs !ustk !bstk (DArgN us bs) = do
  ustk <- prepareArgs ustk (ArgN us)
  bstk <- prepareArgs bstk (ArgN bs)
  pure (ustk, bstk)
{-# INLINE moveArgs #-}

closureArgs :: Stack 'BX -> Args -> IO [Closure]
closureArgs !_ ZArgs = pure []
closureArgs !bstk (BArg1 i) = do
  x <- peekOff bstk i
  pure [x]
closureArgs !bstk (BArg2 i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  pure [x, y]
closureArgs !bstk (BArgR i l) =
  for (take l [i ..]) (peekOff bstk)
closureArgs !bstk (BArgN bs) =
  for (PA.primArrayToList bs) (peekOff bstk)
closureArgs !_ _ =
  error "closure arguments can only be boxed."
{-# INLINE closureArgs #-}

buildData ::
  Stack 'UN -> Stack 'BX -> Reference -> Tag -> Args -> IO Closure
buildData !_ !_ !r !t ZArgs = pure $ Enum r t
buildData !ustk !_ !r !t (UArg1 i) = do
  x <- peekOff ustk i
  pure $ DataU1 r t x
buildData !ustk !_ !r !t (UArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff ustk j
  pure $ DataU2 r t x y
buildData !_ !bstk !r !t (BArg1 i) = do
  x <- peekOff bstk i
  pure $ DataB1 r t x
buildData !_ !bstk !r !t (BArg2 i j) = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  pure $ DataB2 r t x y
buildData !ustk !bstk !r !t (DArg2 i j) = do
  x <- peekOff ustk i
  y <- peekOff bstk j
  pure $ DataUB r t x y
buildData !ustk !_ !r !t (UArgR i l) = do
  useg <- augSeg I ustk unull (Just $ ArgR i l)
  pure $ DataG r t useg bnull
buildData !_ !bstk !r !t (BArgR i l) = do
  bseg <- augSeg I bstk bnull (Just $ ArgR i l)
  pure $ DataG r t unull bseg
buildData !ustk !bstk !r !t (DArgR ui ul bi bl) = do
  useg <- augSeg I ustk unull (Just $ ArgR ui ul)
  bseg <- augSeg I bstk bnull (Just $ ArgR bi bl)
  pure $ DataG r t useg bseg
buildData !ustk !_ !r !t (UArgN as) = do
  useg <- augSeg I ustk unull (Just $ ArgN as)
  pure $ DataG r t useg bnull
buildData !_ !bstk !r !t (BArgN as) = do
  bseg <- augSeg I bstk bnull (Just $ ArgN as)
  pure $ DataG r t unull bseg
buildData !ustk !bstk !r !t (DArgN us bs) = do
  useg <- augSeg I ustk unull (Just $ ArgN us)
  bseg <- augSeg I bstk bnull (Just $ ArgN bs)
  pure $ DataG r t useg bseg
buildData !ustk !bstk !r !t (DArgV ui bi) = do
  useg <-
    if ul > 0
      then augSeg I ustk unull (Just $ ArgR 0 ul)
      else pure unull
  bseg <-
    if bl > 0
      then augSeg I bstk bnull (Just $ ArgR 0 bl)
      else pure bnull
  pure $ DataG r t useg bseg
  where
    ul = fsize ustk - ui
    bl = fsize bstk - bi
{-# INLINE buildData #-}

dumpData ::
  Stack 'UN -> Stack 'BX -> Closure -> IO (Stack 'UN, Stack 'BX)
dumpData !ustk !bstk (Enum _ t) = do
  ustk <- bump ustk
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataU1 _ t x) = do
  ustk <- bumpn ustk 2
  pokeOff ustk 1 x
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataU2 _ t x y) = do
  ustk <- bumpn ustk 3
  pokeOff ustk 2 y
  pokeOff ustk 1 x
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataB1 _ t x) = do
  ustk <- bump ustk
  bstk <- bump bstk
  poke bstk x
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataB2 _ t x y) = do
  ustk <- bump ustk
  bstk <- bumpn bstk 2
  pokeOff bstk 1 y
  poke bstk x
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataUB _ t x y) = do
  ustk <- bumpn ustk 2
  bstk <- bump bstk
  pokeOff ustk 1 x
  poke bstk y
  pokeN ustk t
  pure (ustk, bstk)
dumpData !ustk !bstk (DataG _ t us bs) = do
  ustk <- dumpSeg ustk us S
  bstk <- dumpSeg bstk bs S
  ustk <- bump ustk
  pokeN ustk t
  pure (ustk, bstk)
dumpData !_ !_ clo = die $ "dumpData: bad closure: " ++ show clo
{-# INLINE dumpData #-}

-- Note: although the representation allows it, it is impossible
-- to under-apply one sort of argument while over-applying the
-- other. Thus, it is unnecessary to worry about doing tricks to
-- only grab a certain number of arguments.
closeArgs ::
  Augment ->
  Stack 'UN ->
  Stack 'BX ->
  Seg 'UN ->
  Seg 'BX ->
  Args ->
  IO (Seg 'UN, Seg 'BX)
closeArgs mode !ustk !bstk !useg !bseg args =
  (,) <$> augSeg mode ustk useg uargs
    <*> augSeg mode bstk bseg bargs
  where
    (uargs, bargs) = case args of
      ZArgs -> (Nothing, Nothing)
      UArg1 i -> (Just $ Arg1 i, Nothing)
      BArg1 i -> (Nothing, Just $ Arg1 i)
      UArg2 i j -> (Just $ Arg2 i j, Nothing)
      BArg2 i j -> (Nothing, Just $ Arg2 i j)
      UArgR i l -> (Just $ ArgR i l, Nothing)
      BArgR i l -> (Nothing, Just $ ArgR i l)
      DArg2 i j -> (Just $ Arg1 i, Just $ Arg1 j)
      DArgR ui ul bi bl -> (Just $ ArgR ui ul, Just $ ArgR bi bl)
      UArgN as -> (Just $ ArgN as, Nothing)
      BArgN as -> (Nothing, Just $ ArgN as)
      DArgN us bs -> (Just $ ArgN us, Just $ ArgN bs)
      DArgV ui bi -> (ua, ba)
        where
          ua
            | ul > 0 = Just $ ArgR 0 ul
            | otherwise = Nothing
          ba
            | bl > 0 = Just $ ArgR 0 bl
            | otherwise = Nothing
          ul = fsize ustk - ui
          bl = fsize bstk - bi

peekForeign :: Stack 'BX -> Int -> IO a
peekForeign bstk i =
  peekOff bstk i >>= \case
    Foreign x -> pure $ unwrapForeign x
    _ -> die "bad foreign argument"
{-# INLINE peekForeign #-}

uprim1 :: Stack 'UN -> UPrim1 -> Int -> IO (Stack 'UN)
uprim1 !ustk DECI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (m -1)
  pure ustk
uprim1 !ustk INCI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (m + 1)
  pure ustk
uprim1 !ustk NEGI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (- m)
  pure ustk
uprim1 !ustk SGNI !i = do
  m <- peekOff ustk i
  ustk <- bump ustk
  poke ustk (signum m)
  pure ustk
uprim1 !ustk ABSF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (abs d)
  pure ustk
uprim1 !ustk CEIL !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (ceiling d)
  pure ustk
uprim1 !ustk FLOR !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (floor d)
  pure ustk
uprim1 !ustk TRNF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (truncate d)
  pure ustk
uprim1 !ustk RNDF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  poke ustk (round d)
  pure ustk
uprim1 !ustk EXPF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (exp d)
  pure ustk
uprim1 !ustk LOGF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (log d)
  pure ustk
uprim1 !ustk SQRT !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sqrt d)
  pure ustk
uprim1 !ustk COSF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (cos d)
  pure ustk
uprim1 !ustk SINF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sin d)
  pure ustk
uprim1 !ustk TANF !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (tan d)
  pure ustk
uprim1 !ustk COSH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (cosh d)
  pure ustk
uprim1 !ustk SINH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (sinh d)
  pure ustk
uprim1 !ustk TANH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (tanh d)
  pure ustk
uprim1 !ustk ACOS !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (acos d)
  pure ustk
uprim1 !ustk ASIN !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (asin d)
  pure ustk
uprim1 !ustk ATAN !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (atan d)
  pure ustk
uprim1 !ustk ASNH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (asinh d)
  pure ustk
uprim1 !ustk ACSH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (acosh d)
  pure ustk
uprim1 !ustk ATNH !i = do
  d <- peekOffD ustk i
  ustk <- bump ustk
  pokeD ustk (atanh d)
  pure ustk
uprim1 !ustk ITOF !i = do
  n <- peekOff ustk i
  ustk <- bump ustk
  pokeD ustk (fromIntegral n)
  pure ustk
uprim1 !ustk NTOF !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  pokeD ustk (fromIntegral n)
  pure ustk
uprim1 !ustk LZRO !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  poke ustk (countLeadingZeros n)
  pure ustk
uprim1 !ustk TZRO !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  poke ustk (countTrailingZeros n)
  pure ustk
uprim1 !ustk POPC !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  poke ustk (popCount n)
  pure ustk
uprim1 !ustk COMN !i = do
  n <- peekOffN ustk i
  ustk <- bump ustk
  pokeN ustk (complement n)
  pure ustk
{-# INLINE uprim1 #-}

uprim2 :: Stack 'UN -> UPrim2 -> Int -> Int -> IO (Stack 'UN)
uprim2 !ustk ADDI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m + n)
  pure ustk
uprim2 !ustk SUBI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m - n)
  pure ustk
uprim2 !ustk MULI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m * n)
  pure ustk
uprim2 !ustk DIVI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m `div` n)
  pure ustk
uprim2 !ustk MODI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m `mod` n)
  pure ustk
uprim2 !ustk SHLI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m `shiftL` n)
  pure ustk
uprim2 !ustk SHRI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk (m `shiftR` n)
  pure ustk
uprim2 !ustk SHRN !i !j = do
  m <- peekOffN ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  pokeN ustk (m `shiftR` n)
  pure ustk
uprim2 !ustk POWI !i !j = do
  m <- peekOff ustk i
  n <- peekOffN ustk j
  ustk <- bump ustk
  poke ustk (m ^ n)
  pure ustk
uprim2 !ustk EQLI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk $ if m == n then 1 else 0
  pure ustk
uprim2 !ustk LEQI !i !j = do
  m <- peekOff ustk i
  n <- peekOff ustk j
  ustk <- bump ustk
  poke ustk $ if m <= n then 1 else 0
  pure ustk
uprim2 !ustk LEQN !i !j = do
  m <- peekOffN ustk i
  n <- peekOffN ustk j
  ustk <- bump ustk
  poke ustk $ if m <= n then 1 else 0
  pure ustk
uprim2 !ustk ADDF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x + y)
  pure ustk
uprim2 !ustk SUBF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x - y)
  pure ustk
uprim2 !ustk MULF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x * y)
  pure ustk
uprim2 !ustk DIVF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x / y)
  pure ustk
uprim2 !ustk LOGB !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (logBase x y)
  pure ustk
uprim2 !ustk POWF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (x ** y)
  pure ustk
uprim2 !ustk MAXF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (max x y)
  pure ustk
uprim2 !ustk MINF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (min x y)
  pure ustk
uprim2 !ustk EQLF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (if x == y then 1 else 0)
  pure ustk
uprim2 !ustk LEQF !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (if x <= y then 1 else 0)
  pure ustk
uprim2 !ustk ATN2 !i !j = do
  x <- peekOffD ustk i
  y <- peekOffD ustk j
  ustk <- bump ustk
  pokeD ustk (atan2 x y)
  pure ustk
uprim2 !ustk ANDN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (x .&. y)
  pure ustk
uprim2 !ustk IORN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (x .|. y)
  pure ustk
uprim2 !ustk XORN !i !j = do
  x <- peekOffN ustk i
  y <- peekOffN ustk j
  ustk <- bump ustk
  pokeN ustk (xor x y)
  pure ustk
{-# INLINE uprim2 #-}

bprim1 ::
  Stack 'UN ->
  Stack 'BX ->
  BPrim1 ->
  Int ->
  IO (Stack 'UN, Stack 'BX)
bprim1 !ustk !bstk SIZT i = do
  t <- peekOffBi bstk i
  ustk <- bump ustk
  poke ustk $ Tx.length t
  pure (ustk, bstk)
bprim1 !ustk !bstk SIZS i = do
  s <- peekOffS bstk i
  ustk <- bump ustk
  poke ustk $ Sq.length s
  pure (ustk, bstk)
bprim1 !ustk !bstk ITOT i = do
  n <- peekOff ustk i
  bstk <- bump bstk
  pokeBi bstk . Tx.pack $ show n
  pure (ustk, bstk)
bprim1 !ustk !bstk NTOT i = do
  n <- peekOffN ustk i
  bstk <- bump bstk
  pokeBi bstk . Tx.pack $ show n
  pure (ustk, bstk)
bprim1 !ustk !bstk FTOT i = do
  f <- peekOffD ustk i
  bstk <- bump bstk
  pokeBi bstk . Tx.pack $ show f
  pure (ustk, bstk)
bprim1 !ustk !bstk USNC i =
  peekOffBi bstk i >>= \t -> case Tx.unsnoc t of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just (t, c) -> do
      ustk <- bumpn ustk 2
      bstk <- bump bstk
      pokeOff ustk 1 $ fromEnum c
      poke ustk 1
      pokeBi bstk t
      pure (ustk, bstk)
bprim1 !ustk !bstk UCNS i =
  peekOffBi bstk i >>= \t -> case Tx.uncons t of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just (c, t) -> do
      ustk <- bumpn ustk 2
      bstk <- bump bstk
      pokeOff ustk 1 $ fromEnum c
      poke ustk 1
      pokeBi bstk t
      pure (ustk, bstk)
bprim1 !ustk !bstk TTOI i =
  peekOffBi bstk i >>= \t -> case readm $ Tx.unpack t of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just n -> do
      ustk <- bumpn ustk 2
      poke ustk 1
      pokeOff ustk 1 n
      pure (ustk, bstk)
  where
    readm ('+' : s) = readMaybe s
    readm s = readMaybe s
bprim1 !ustk !bstk TTON i =
  peekOffBi bstk i >>= \t -> case readMaybe $ Tx.unpack t of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just n -> do
      ustk <- bumpn ustk 2
      poke ustk 1
      pokeOffN ustk 1 n
      pure (ustk, bstk)
bprim1 !ustk !bstk TTOF i =
  peekOffBi bstk i >>= \t -> case readMaybe $ Tx.unpack t of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just f -> do
      ustk <- bumpn ustk 2
      poke ustk 1
      pokeOffD ustk 1 f
      pure (ustk, bstk)
bprim1 !ustk !bstk VWLS i =
  peekOffS bstk i >>= \case
    Sq.Empty -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    x Sq.:<| xs -> do
      ustk <- bump ustk
      poke ustk 1
      bstk <- bumpn bstk 2
      pokeOffS bstk 1 xs
      poke bstk x
      pure (ustk, bstk)
bprim1 !ustk !bstk VWRS i =
  peekOffS bstk i >>= \case
    Sq.Empty -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    xs Sq.:|> x -> do
      ustk <- bump ustk
      poke ustk 1
      bstk <- bumpn bstk 2
      pokeOff bstk 1 x
      pokeS bstk xs
      pure (ustk, bstk)
bprim1 !ustk !bstk PAKT i = do
  s <- peekOffS bstk i
  bstk <- bump bstk
  pokeBi bstk . Tx.pack . toList $ clo2char <$> s
  pure (ustk, bstk)
  where
    clo2char (DataU1 _ 0 i) = toEnum i
    clo2char c = error $ "pack text: non-character closure: " ++ show c
bprim1 !ustk !bstk UPKT i = do
  t <- peekOffBi bstk i
  bstk <- bump bstk
  pokeS bstk . Sq.fromList
    . fmap (DataU1 Rf.charRef 0 . fromEnum)
    . Tx.unpack
    $ t
  pure (ustk, bstk)
bprim1 !ustk !bstk PAKB i = do
  s <- peekOffS bstk i
  bstk <- bump bstk
  pokeBi bstk . By.fromWord8s . fmap clo2w8 $ toList s
  pure (ustk, bstk)
  where
    clo2w8 (DataU1 _ 0 n) = toEnum n
    clo2w8 c = error $ "pack bytes: non-natural closure: " ++ show c
bprim1 !ustk !bstk UPKB i = do
  b <- peekOffBi bstk i
  bstk <- bump bstk
  pokeS bstk . Sq.fromList . fmap (DataU1 Rf.natRef 0 . fromEnum) $
    By.toWord8s b
  pure (ustk, bstk)
bprim1 !ustk !bstk SIZB i = do
  b <- peekOffBi bstk i
  ustk <- bump ustk
  poke ustk $ By.size b
  pure (ustk, bstk)
bprim1 !ustk !bstk FLTB i = do
  b <- peekOffBi bstk i
  bstk <- bump bstk
  pokeBi bstk $ By.flatten b
  pure (ustk, bstk)
bprim1 !_ !bstk THRO i =
  throwIO . BU =<< peekOff bstk i
-- impossible
bprim1 !ustk !bstk MISS _ = pure (ustk, bstk)
bprim1 !ustk !bstk CACH _ = pure (ustk, bstk)
bprim1 !ustk !bstk LKUP _ = pure (ustk, bstk)
bprim1 !ustk !bstk LOAD _ = pure (ustk, bstk)
bprim1 !ustk !bstk VALU _ = pure (ustk, bstk)
{-# INLINE bprim1 #-}

bprim2 ::
  Stack 'UN ->
  Stack 'BX ->
  BPrim2 ->
  Int ->
  Int ->
  IO (Stack 'UN, Stack 'BX)
bprim2 !ustk !bstk EQLU i j = do
  x <- peekOff bstk i
  y <- peekOff bstk j
  ustk <- bump ustk
  poke ustk $ if x == y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk DRPT i j = do
  n <- peekOff ustk i
  t <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk $ Tx.drop n t
  pure (ustk, bstk)
bprim2 !ustk !bstk CATT i j = do
  x <- peekOffBi bstk i
  y <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk $ Tx.append x y
  pure (ustk, bstk)
bprim2 !ustk !bstk TAKT i j = do
  n <- peekOff ustk i
  t <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk $ Tx.take n t
  pure (ustk, bstk)
bprim2 !ustk !bstk EQLT i j = do
  x <- peekOffBi @Tx.Text bstk i
  y <- peekOffBi bstk j
  ustk <- bump ustk
  poke ustk $ if x == y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk LEQT i j = do
  x <- peekOffBi @Tx.Text bstk i
  y <- peekOffBi bstk j
  ustk <- bump ustk
  poke ustk $ if x <= y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk LEST i j = do
  x <- peekOffBi @Tx.Text bstk i
  y <- peekOffBi bstk j
  ustk <- bump ustk
  poke ustk $ if x < y then 1 else 0
  pure (ustk, bstk)
bprim2 !ustk !bstk DRPS i j = do
  n <- peekOff ustk i
  s <- peekOffS bstk j
  bstk <- bump bstk
  pokeS bstk $ Sq.drop n s
  pure (ustk, bstk)
bprim2 !ustk !bstk TAKS i j = do
  n <- peekOff ustk i
  s <- peekOffS bstk j
  bstk <- bump bstk
  pokeS bstk $ Sq.take n s
  pure (ustk, bstk)
bprim2 !ustk !bstk CONS i j = do
  x <- peekOff bstk i
  s <- peekOffS bstk j
  bstk <- bump bstk
  pokeS bstk $ x Sq.<| s
  pure (ustk, bstk)
bprim2 !ustk !bstk SNOC i j = do
  s <- peekOffS bstk i
  x <- peekOff bstk j
  bstk <- bump bstk
  pokeS bstk $ s Sq.|> x
  pure (ustk, bstk)
bprim2 !ustk !bstk CATS i j = do
  x <- peekOffS bstk i
  y <- peekOffS bstk j
  bstk <- bump bstk
  pokeS bstk $ x Sq.>< y
  pure (ustk, bstk)
bprim2 !ustk !bstk IDXS i j = do
  n <- peekOff ustk i
  s <- peekOffS bstk j
  case Sq.lookup n s of
    Nothing -> do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    Just x -> do
      ustk <- bump ustk
      poke ustk 1
      bstk <- bump bstk
      poke bstk x
      pure (ustk, bstk)
bprim2 !ustk !bstk SPLL i j = do
  n <- peekOff ustk i
  s <- peekOffS bstk j
  if Sq.length s < n
    then do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    else do
      ustk <- bump ustk
      poke ustk 1
      bstk <- bumpn bstk 2
      let (l, r) = Sq.splitAt n s
      pokeOffS bstk 1 r
      pokeS bstk l
      pure (ustk, bstk)
bprim2 !ustk !bstk SPLR i j = do
  n <- peekOff ustk i
  s <- peekOffS bstk j
  if Sq.length s < n
    then do
      ustk <- bump ustk
      poke ustk 0
      pure (ustk, bstk)
    else do
      ustk <- bump ustk
      poke ustk 1
      bstk <- bumpn bstk 2
      let (l, r) = Sq.splitAt (Sq.length s - n) s
      pokeOffS bstk 1 r
      pokeS bstk l
      pure (ustk, bstk)
bprim2 !ustk !bstk TAKB i j = do
  n <- peekOff ustk i
  b <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk $ By.take n b
  pure (ustk, bstk)
bprim2 !ustk !bstk DRPB i j = do
  n <- peekOff ustk i
  b <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk $ By.drop n b
  pure (ustk, bstk)
bprim2 !ustk !bstk IDXB i j = do
  n <- peekOff ustk i
  b <- peekOffBi bstk j
  ustk <- bump ustk
  ustk <- case By.at n b of
    Nothing -> ustk <$ poke ustk 0
    Just x -> do
      poke ustk $ fromIntegral x
      ustk <- bump ustk
      ustk <$ poke ustk 0
  pure (ustk, bstk)
bprim2 !ustk !bstk CATB i j = do
  l <- peekOffBi bstk i
  r <- peekOffBi bstk j
  bstk <- bump bstk
  pokeBi bstk (l <> r :: By.Bytes)
  pure (ustk, bstk)
bprim2 !ustk !bstk CMPU _ _ = pure (ustk, bstk) -- impossible
{-# INLINE bprim2 #-}

yield ::
  CCache ->
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  IO ()
yield !env !denv !ustk !bstk !k = leap denv k
  where
    leap !denv0 (Mark ps cs k) = do
      let denv = cs <> EC.withoutKeys denv0 ps
          clo = denv0 EC.! EC.findMin ps
      poke bstk . DataB1 Rf.effectRef 0 =<< peek bstk
      apply env denv ustk bstk k False (BArg1 0) clo
    leap !denv (Push ufsz bfsz uasz basz cix k) = do
      Lam _ _ _ _ nx <- combSection env cix
      ustk <- restoreFrame ustk ufsz uasz
      bstk <- restoreFrame bstk bfsz basz
      eval env denv ustk bstk k nx
    leap _ (CB (Hook f)) = f ustk bstk
    leap _ KE = pure ()
{-# INLINE yield #-}

selectTextBranch ::
  Tx.Text -> Section -> M.Map Tx.Text Section -> Section
selectTextBranch t df cs = M.findWithDefault df t cs
{-# INLINE selectTextBranch #-}

selectBranch :: Tag -> Branch -> Section
selectBranch t (Test1 u y n)
  | t == u = y
  | otherwise = n
selectBranch t (Test2 u cu v cv e)
  | t == u = cu
  | t == v = cv
  | otherwise = e
selectBranch t (TestW df cs) = lookupWithDefault df t cs
selectBranch _ (TestT {}) = error "impossible"
{-# INLINE selectBranch #-}

splitCont ::
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Word64 ->
  IO (K, DEnv, Stack 'UN, Stack 'BX, Seg 'UN, Seg 'BX, K)
splitCont !denv !ustk !bstk !k !p =
  walk denv (asize ustk) (asize bstk) KE k
  where
    walk !denv !usz !bsz !ck KE =
      die "fell off stack" >> finish denv usz bsz ck KE
    walk !denv !usz !bsz !ck (CB _) =
      die "fell off stack" >> finish denv usz bsz ck KE
    walk !denv !usz !bsz !ck (Mark ps cs k)
      | EC.member p ps = finish denv' usz bsz ck k
      | otherwise = walk denv' usz bsz (Mark ps cs' ck) k
      where
        denv' = cs <> EC.withoutKeys denv ps
        cs' = EC.restrictKeys denv ps
    walk !denv !usz !bsz !ck (Push un bn ua ba br k) =
      walk denv (usz + un + ua) (bsz + bn + ba) (Push un bn ua ba br ck) k

    finish !denv !usz !bsz !ck !k = do
      (useg, ustk) <- grab ustk usz
      (bseg, bstk) <- grab bstk bsz
      return (ck, denv, ustk, bstk, useg, bseg, k)
{-# INLINE splitCont #-}

discardCont ::
  DEnv ->
  Stack 'UN ->
  Stack 'BX ->
  K ->
  Word64 ->
  IO (DEnv, Stack 'UN, Stack 'BX, K)
discardCont denv ustk bstk k p =
  splitCont denv ustk bstk k p
    <&> \(_, denv, ustk, bstk, _, _, k) -> (denv, ustk, bstk, k)
{-# INLINE discardCont #-}

resolve :: CCache -> DEnv -> Stack 'BX -> Ref -> IO Closure
resolve env _ _ (Env n i) =
  readTVarIO (combRefs env) >>= \rs -> case EC.lookup n rs of
    Just r -> pure $ PAp (CIx r n i) unull bnull
    Nothing -> die $ "resolve: missing reference for comb: " ++ show n
resolve _ _ bstk (Stk i) = peekOff bstk i
resolve _ denv _ (Dyn i) = case EC.lookup i denv of
  Just clo -> pure clo
  _ -> die $ "resolve: looked up bad dynamic: " ++ show i

combSection :: HasCallStack => CCache -> CombIx -> IO Comb
combSection env (CIx _ n i) =
  readTVarIO (combs env) >>= \cs -> case EC.lookup n cs of
    Just cmbs -> case EC.lookup i cmbs of
      Just cmb -> pure cmb
      Nothing ->
        die $
          "unknown section `" ++ show i
            ++ "` of combinator `"
            ++ show n
            ++ "`."
    Nothing -> die $ "unknown combinator `" ++ show n ++ "`."

dummyRef :: Reference
dummyRef = Builtin (Tx.pack "dummy")

reserveIds :: Word64 -> TVar Word64 -> IO Word64
reserveIds n free = atomically . stateTVar free $ \i -> (i, i + n)

updateMap :: Semigroup s => s -> TVar s -> STM s
updateMap new r = stateTVar r $ \old ->
  let total = new <> old in (total, total)

refLookup :: String -> M.Map Reference Word64 -> Reference -> Word64
refLookup s m r
  | Just w <- M.lookup r m = w
  | otherwise =
    error $ "refLookup:" ++ s ++ ": unknown reference: " ++ show r

decodeCacheArgument ::
  Sq.Seq Closure -> IO [(Reference, SuperGroup Symbol)]
decodeCacheArgument s = for (toList s) $ \case
  DataB2 _ _ (Foreign x) (DataB2 _ _ (Foreign y) _) ->
    pure (unwrapForeign x, unwrapForeign y)
  _ -> die "decodeCacheArgument: unrecognized value"

addRefs ::
  TVar Word64 ->
  TVar (M.Map Reference Word64) ->
  TVar (EnumMap Word64 Reference) ->
  S.Set Reference ->
  STM (M.Map Reference Word64)
addRefs vfrsh vfrom vto rs = do
  from0 <- readTVar vfrom
  let new = S.filter (`M.notMember` from0) rs
      sz = fromIntegral $ S.size new
  frsh <- stateTVar vfrsh $ \i -> (i, i + sz)
  let newl = S.toList new
      from = M.fromList (zip newl [frsh ..]) <> from0
      nto = mapFromList (zip [frsh ..] newl)
  writeTVar vfrom from
  modifyTVar vto (nto <>)
  pure from

cacheAdd0 ::
  S.Set Reference ->
  [(Reference, SuperGroup Symbol)] ->
  CCache ->
  IO ()
cacheAdd0 ntys0 tml cc = atomically $ do
  have <- readTVar (intermed cc)
  let new = M.difference toAdd have
      sz = fromIntegral $ M.size new
      (rs, gs) = unzip $ M.toList new
  rty <- addRefs (freshTy cc) (refTy cc) (tagRefs cc) ntys0
  ntm <- stateTVar (freshTm cc) $ \i -> (i, i + sz)
  rtm <- updateMap (M.fromList $ zip rs [ntm ..]) (refTm cc)
  -- check for missing references
  let rns = RN (refLookup "ty" rty) (refLookup "tm" rtm)
      combinate n g = (n, emitCombs rns n g)
  nrs <- updateMap (mapFromList $ zip [ntm ..] rs) (combRefs cc)
  ncs <- updateMap (mapFromList $ zipWith combinate [ntm ..] gs) (combs cc)
  pure $ rtm `seq` nrs `seq` ncs `seq` ()
  where
    toAdd = M.fromList tml

cacheAdd ::
  [(Reference, SuperGroup Symbol)] ->
  CCache ->
  IO [Reference]
cacheAdd l cc = do
  rtm <- readTVarIO (refTm cc)
  rty <- readTVarIO (refTy cc)
  let known = M.keysSet rtm <> S.fromList (fst <$> l)
      f b r
        | not b, S.notMember r known = (S.singleton r, mempty)
        | b, M.notMember r rty = (mempty, S.singleton r)
        | otherwise = (mempty, mempty)
      (missing, tys) = (foldMap . foldMap) (groupLinks f) l
      l' = filter (\(r, _) -> M.notMember r rtm) l
  if S.null missing
    then [] <$ cacheAdd0 tys l' cc
    else pure $ S.toList missing

reflectValue :: EnumMap Word64 Reference -> Closure -> IO ANF.Value
reflectValue rty = goV
  where
    err s = "reflectValue: cannot prepare value for serialization: " ++ s
    refTy w
      | Just r <- EC.lookup w rty = pure r
      | otherwise =
        die $ err "unknown type reference"

    goIx (CIx r n i) = ANF.GR r n i

    goV (PApV cix ua ba) =
      ANF.Partial (goIx cix) (fromIntegral <$> ua) <$> traverse goV ba
    goV (DataC r t us bs) =
      ANF.Data r t (fromIntegral <$> us) <$> traverse goV bs
    goV (CapV k us bs) =
      ANF.Cont (fromIntegral <$> us) <$> traverse goV bs <*> goK k
    goV (Foreign _) = die $ err "foreign value"
    goV BlackHole = die $ err "black hole"

    goK (CB _) = die $ err "callback continuation"
    goK KE = pure ANF.KE
    goK (Mark ps de k) = do
      ps <- traverse refTy (EC.setToList ps)
      de <- traverse (\(k, v) -> (,) <$> refTy k <*> goV v) (mapToList de)
      ANF.Mark ps (M.fromList de) <$> goK k
    goK (Push uf bf ua ba cix k) =
      ANF.Push
        (fromIntegral uf)
        (fromIntegral bf)
        (fromIntegral ua)
        (fromIntegral ba)
        (goIx cix)
        <$> goK k

reifyValue :: CCache -> ANF.Value -> IO (Either [Reference] Closure)
reifyValue cc val = do
  erc <-
    atomically $
      readTVar (refTm cc) >>= \rtm ->
        case S.toList $ S.filter (`M.notMember` rtm) tmLinks of
          [] ->
            Right
              <$> addRefs (freshTy cc) (refTy cc) (tagRefs cc) tyLinks
          l -> pure (Left l)
  traverse (\rty -> reifyValue0 rty val) erc
  where
    f False r = (mempty, S.singleton r)
    f True r = (S.singleton r, mempty)
    (tyLinks, tmLinks) = valueLinks f val

reifyValue0 :: M.Map Reference Word64 -> ANF.Value -> IO Closure
reifyValue0 rty = goV
  where
    err s = "reifyValue: cannot restore value: " ++ s
    refTy r
      | Just w <- M.lookup r rty = pure w
      | otherwise = die . err $ "unknown type reference: " ++ show r
    goIx (ANF.GR r n i) = CIx r n i

    goV (ANF.Partial gr ua ba) =
      PApV (goIx gr) (fromIntegral <$> ua) <$> traverse goV ba
    goV (ANF.Data r t us bs) =
      DataC r t (fromIntegral <$> us) <$> traverse goV bs
    goV (ANF.Cont us bs k) = cv <$> goK k <*> traverse goV bs
      where
        cv k bs = CapV k (fromIntegral <$> us) bs

    goK ANF.KE = pure KE
    goK (ANF.Mark ps de k) =
      mrk <$> traverse refTy ps
        <*> traverse (\(k, v) -> (,) <$> refTy k <*> goV v) (M.toList de)
        <*> goK k
      where
        mrk ps de k = Mark (setFromList ps) (mapFromList de) k
    goK (ANF.Push uf bf ua ba gr k) =
      Push
        (fromIntegral uf)
        (fromIntegral bf)
        (fromIntegral ua)
        (fromIntegral ba)
        (goIx gr)
        <$> goK k
