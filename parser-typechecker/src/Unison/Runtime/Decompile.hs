{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TupleSections #-}

module Unison.Runtime.Decompile (decompile) where

import Unison.ABT (absChain, substs, pattern AbsN')
import Unison.Codebase.Runtime (Error)
import Unison.Prelude
import Unison.Reference (Reference)
import Unison.Runtime.Foreign
  ( Foreign,
    HashAlgorithm (..),
    maybeUnwrapBuiltin,
    maybeUnwrapForeign,
  )
import Unison.Runtime.MCode (CombIx (..))
import Unison.Runtime.Stack
  ( Closure (..),
    pattern DataC,
    pattern PApV,
  )
import Unison.Term
  ( Term,
    app,
    apps',
    boolean,
    builtin,
    char,
    constructor,
    float,
    int,
    nat,
    ref,
    seq,
    seq',
    termLink,
    text,
    typeLink,
  )
import Unison.Type
  ( booleanRef,
    charRef,
    floatRef,
    intRef,
    natRef,
    termLinkRef,
    typeLinkRef,
    vectorRef,
  )
import qualified Unison.Util.Bytes as By
import Unison.Util.Pretty (lit)
import Unison.Var (Var)
import Unsafe.Coerce -- for Int -> Double
import Prelude hiding (seq)

con :: Var v => Reference -> Word64 -> Term v ()
con rf ct = constructor () rf $ fromIntegral ct

err :: String -> Either Error a
err = Left . lit . fromString

decompile ::
  Var v =>
  (Word64 -> Maybe (Term v ())) ->
  Closure ->
  Either Error (Term v ())
decompile _ (DataC rf ct [] [])
  | rf == booleanRef =
    boolean () <$> tag2bool ct
decompile _ (DataC rf ct [i] []) =
  decompileUnboxed rf ct i
decompile topTerms (DataC rf ct [] bs) =
  apps' (con rf ct) <$> traverse (decompile topTerms) bs
decompile _ (PApV (CIx _ _ n) _ _)
  | n > 0 =
    err "cannot decompile an application to a local recusive binding"
decompile topTerms (PApV (CIx _ rt 0) [] bs)
  | Just t <- topTerms rt =
    substitute t <$> traverse (decompile topTerms) bs
  | otherwise =
    err "reference to unknown combinator"
decompile _ cl@(PAp _ _ _) =
  err $
    "cannot decompile a partial application to unboxed values: "
      ++ show cl
decompile _ (DataC {}) =
  err "cannot decompile data type with multiple unboxed fields"
decompile _ BlackHole = err "exception"
decompile _ (Captured {}) = err "decompiling a captured continuation"
decompile topTerms (Foreign f) = decompileForeign topTerms f

tag2bool :: Word64 -> Either Error Bool
tag2bool 0 = Right False
tag2bool 1 = Right True
tag2bool _ = err "bad boolean tag"

substitute :: Var v => Term v () -> [Term v ()] -> Term v ()
substitute (AbsN' vs bd) ts = align [] vs ts
  where
    align vts (v : vs) (t : ts) = align ((v, t) : vts) vs ts
    align vts vs [] = substs vts (absChain vs bd)
    -- this should not happen
    align vts [] ts = apps' (substs vts bd) ts
-- TODO: these aliases are not actually very conveniently written
substitute _ _ = error "impossible"

decompileUnboxed ::
  Var v => Reference -> Word64 -> Int -> Either Error (Term v ())
decompileUnboxed r _ i
  | r == natRef = pure . nat () $ fromIntegral i
  | r == intRef = pure . int () $ fromIntegral i
  | r == floatRef = pure . float () $ unsafeCoerce i
  | r == charRef = pure . char () $ toEnum i
decompileUnboxed r _ _ =
  err $ "cannot decompile unboxed data type with reference: " ++ show r

decompileForeign ::
  Var v =>
  (Word64 -> Maybe (Term v ())) ->
  Foreign ->
  Either Error (Term v ())
decompileForeign topTerms f
  | Just t <- maybeUnwrapBuiltin f = Right $ text () t
  | Just b <- maybeUnwrapBuiltin f = Right $ decompileBytes b
  | Just h <- maybeUnwrapBuiltin f = Right $ decompileHashAlgorithm h
  | Just l <- maybeUnwrapForeign termLinkRef f =
    Right $ termLink () l
  | Just l <- maybeUnwrapForeign typeLinkRef f =
    Right $ typeLink () l
  | Just s <- unwrapSeq f =
    seq' () <$> traverse (decompile topTerms) s
decompileForeign _ _ = err "cannot decompile Foreign"

decompileBytes :: Var v => By.Bytes -> Term v ()
decompileBytes =
  app () (builtin () $ fromString "Bytes.fromList")
    . seq ()
    . fmap (nat () . fromIntegral)
    . By.toWord8s

decompileHashAlgorithm :: Var v => HashAlgorithm -> Term v ()
decompileHashAlgorithm (HashAlgorithm r _) = ref () r

unwrapSeq :: Foreign -> Maybe (Seq Closure)
unwrapSeq = maybeUnwrapForeign vectorRef
