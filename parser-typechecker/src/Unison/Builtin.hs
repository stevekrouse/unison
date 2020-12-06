{-# LANGUAGE ExplicitForAll #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TypeApplications #-}

module Unison.Builtin
  ( codeLookup,
    constructorType,
    names,
    names0,
    builtinDataDecls,
    builtinEffectDecls,
    builtinConstructorType,
    builtinTypeDependents,
    builtinTypes,
    builtinTermsByType,
    builtinTermsByTypeMention,
    intrinsicTermReferences,
    intrinsicTypeReferences,
    isBuiltinType,
    typeLookup,
    termRefTypes,
  )
where

import Data.Bifunctor (first, second)
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Data.Text as Text
import qualified Text.Regex.TDFA as RE
import qualified Unison.Builtin.Decls as DD
import Unison.Codebase.CodeLookup (CodeLookup (..))
import qualified Unison.ConstructorType as CT
import qualified Unison.DataDeclaration as DD
import Unison.Name (Name)
import qualified Unison.Name as Name
import Unison.Names3 (Names (Names), Names0)
import qualified Unison.Names3 as Names3
import Unison.Parser (Ann (..))
import Unison.Prelude
import qualified Unison.Reference as R
import qualified Unison.Referent as Referent
import Unison.Symbol (Symbol)
import qualified Unison.Type as Type
import qualified Unison.Typechecker.TypeLookup as TL
import qualified Unison.Util.Relation as Rel
import Unison.Var (Var)
import qualified Unison.Var as Var

type DataDeclaration v = DD.DataDeclaration v Ann

type EffectDeclaration v = DD.EffectDeclaration v Ann

type Type v = Type.Type v ()

names :: Names
names = Names names0 mempty

names0 :: Names0
names0 = Names3.names0 terms types
  where
    terms =
      Rel.mapRan Referent.Ref (Rel.fromMap termNameRefs)
        <> Rel.fromList
          [ (Name.fromVar vc, Referent.Con (R.DerivedId r) cid ct)
            | (ct, (_, (r, decl))) <-
                ((CT.Data,) <$> builtinDataDecls @Symbol)
                  <> ((CT.Effect,) . (second . second) DD.toDataDecl <$> builtinEffectDecls),
              ((_, vc, _), cid) <- DD.constructors' decl `zip` [0 ..]
          ]
    types =
      Rel.fromList builtinTypes
        <> Rel.fromList
          [ (Name.fromVar v, R.DerivedId r)
            | (v, (r, _)) <- builtinDataDecls @Symbol
          ]
        <> Rel.fromList
          [ (Name.fromVar v, R.DerivedId r)
            | (v, (r, _)) <- builtinEffectDecls @Symbol
          ]

-- note: this function is really for deciding whether `r` is a term or type,
-- but it can only answer correctly for Builtins.
isBuiltinType :: R.Reference -> Bool
isBuiltinType r = elem r . fmap snd $ builtinTypes

typeLookup :: Var v => TL.TypeLookup v Ann
typeLookup =
  TL.TypeLookup
    (fmap (const Intrinsic) <$> termRefTypes)
    (Map.fromList . map (first R.DerivedId) $ map snd builtinDataDecls)
    (Map.fromList . map (first R.DerivedId) $ map snd builtinEffectDecls)

constructorType :: R.Reference -> Maybe CT.ConstructorType
constructorType r =
  TL.constructorType (typeLookup @Symbol) r
    <|> Map.lookup r builtinConstructorType

builtinDataDecls :: Var v => [(v, (R.Id, DataDeclaration v))]
builtinDataDecls =
  [(v, (r, Intrinsic <$ d)) | (v, r, d) <- DD.builtinDataDecls]

builtinEffectDecls :: Var v => [(v, (R.Id, EffectDeclaration v))]
builtinEffectDecls = [(v, (r, Intrinsic <$ d)) | (v, r, d) <- DD.builtinEffectDecls]

codeLookup :: (Applicative m, Var v) => CodeLookup v m Ann
codeLookup = CodeLookup (const $ pure Nothing) $ \r ->
  pure $
    lookup r [(r, Right x) | (r, x) <- snd <$> builtinDataDecls]
      <|> lookup r [(r, Left x) | (r, x) <- snd <$> builtinEffectDecls]

-- Relation predicate: Domain depends on range.
builtinDependencies :: Rel.Relation R.Reference R.Reference
builtinDependencies =
  Rel.fromMultimap (Type.dependencies <$> termRefTypes @Symbol)

-- a relation whose domain is types and whose range is builtin terms with that type
builtinTermsByType :: Rel.Relation R.Reference Referent.Referent
builtinTermsByType =
  Rel.fromList
    [ (Type.toReference ty, Referent.Ref r)
      | (r, ty) <- Map.toList (termRefTypes @Symbol)
    ]

-- a relation whose domain is types and whose range is builtin terms that mention that type
-- example: Nat.+ mentions the type `Nat`
builtinTermsByTypeMention :: Rel.Relation R.Reference Referent.Referent
builtinTermsByTypeMention =
  Rel.fromList
    [ (m, Referent.Ref r) | (r, ty) <- Map.toList (termRefTypes @Symbol), m <- toList $ Type.toReferenceMentions ty
    ]

-- The dependents of a builtin type is the set of builtin terms which
-- mention that type.
builtinTypeDependents :: R.Reference -> Set R.Reference
builtinTypeDependents r = Rel.lookupRan r builtinDependencies

-- WARNING:
-- As with the terms, we should avoid changing these references, even
-- if we decide to change their names.
builtinTypes :: [(Name, R.Reference)]
builtinTypes =
  Map.toList . Map.mapKeys Name.unsafeFromText $
    foldl' go mempty builtinTypesSrc
  where
    go m = \case
      B' r _ -> Map.insert r (R.Builtin r) m
      D' r -> Map.insert r (R.Builtin r) m
      Rename' r name -> case Map.lookup name m of
        Just _ ->
          error . Text.unpack $
            "tried to rename `" <> r <> "` to `" <> name <> "`, "
              <> "which already exists."
        Nothing -> case Map.lookup r m of
          Nothing ->
            error . Text.unpack $
              "tried to rename `" <> r <> "` before it was declared."
          Just t -> Map.insert name t . Map.delete r $ m
      Alias' r name -> case Map.lookup name m of
        Just _ ->
          error . Text.unpack $
            "tried to alias `" <> r <> "` to `" <> name <> "`, "
              <> "which already exists."
        Nothing -> case Map.lookup r m of
          Nothing ->
            error . Text.unpack $
              "tried to alias `" <> r <> "` before it was declared."
          Just t -> Map.insert name t m

-- WARNING: Don't delete any of these lines, only add corrections.
builtinTypesSrc :: [BuiltinTypeDSL]
builtinTypesSrc =
  [ B' "Int" CT.Data,
    B' "Nat" CT.Data,
    B' "Float" CT.Data,
    B' "Boolean" CT.Data,
    B' "Sequence" CT.Data,
    Rename' "Sequence" "List",
    B' "Text" CT.Data,
    B' "Char" CT.Data,
    B' "Effect" CT.Data,
    Rename' "Effect" "Request",
    B' "Bytes" CT.Data,
    B' "Link.Term" CT.Data,
    B' "Link.Type" CT.Data,
    B' "IO" CT.Effect,
    Rename' "IO" "io2.IO",
    B' "Handle" CT.Data,
    Rename' "Handle" "io2.Handle",
    B' "Socket" CT.Data,
    Rename' "Socket" "io2.Socket",
    B' "ThreadId" CT.Data,
    Rename' "ThreadId" "io2.ThreadId",
    B' "MVar" CT.Data,
    Rename' "MVar" "io2.MVar",
    B' "Code" CT.Data,
    B' "Value" CT.Data,
    B' "crypto.HashAlgorithm" CT.Data,
    B' "Tls" CT.Data,
    Rename' "Tls" "io2.Tls",
    B' "Tls.ClientConfig" CT.Data,
    Rename' "Tls.ClientConfig" "io2.Tls.ClientConfig",
    B' "Tls.ServerConfig" CT.Data,
    Rename' "Tls.ServerConfig" "io2.Tls.ServerConfig"
  ]

-- rename these to "builtin" later, when builtin means intrinsic as opposed to
-- stuff that intrinsics depend on.
intrinsicTypeReferences :: Set R.Reference
intrinsicTypeReferences = foldl' go mempty builtinTypesSrc
  where
    go acc = \case
      B' r _ -> Set.insert (R.Builtin r) acc
      D' r -> Set.insert (R.Builtin r) acc
      _ -> acc

intrinsicTermReferences :: Set R.Reference
intrinsicTermReferences = Map.keysSet (termRefTypes @Symbol)

builtinConstructorType :: Map R.Reference CT.ConstructorType
builtinConstructorType = Map.fromList [(R.Builtin r, ct) | B' r ct <- builtinTypesSrc]

data BuiltinTypeDSL = B' Text CT.ConstructorType | D' Text | Rename' Text Text | Alias' Text Text

data BuiltinDSL v
  = -- simple builtin: name=ref, type
    B Text (Type v)
  | -- deprecated builtin: name=ref, type (TBD)
    D Text (Type v)
  | -- rename builtin: refname, newname
    -- must not appear before corresponding B/D
    -- will overwrite newname
    Rename Text Text
  | -- alias builtin: refname, newname
    -- must not appear before corresponding B/D
    -- will overwrite newname
    Alias Text Text

instance Show (BuiltinDSL v) where
  show (B t _) = Text.unpack $ "B" <> t
  show (Rename from to) = Text.unpack $ "Rename " <> from <> " to " <> to
  show _ = ""

termNameRefs :: Map Name R.Reference
termNameRefs = Map.mapKeys Name.unsafeFromText $ foldl' go mempty (stripVersion $ builtinsSrc @Symbol)
  where
    go m = \case
      B r _tp -> Map.insert r (R.Builtin r) m
      D r _tp -> Map.insert r (R.Builtin r) m
      Rename r name -> case Map.lookup name m of
        Just _ ->
          error . Text.unpack $
            "tried to rename `" <> r <> "` to `" <> name <> "`, "
              <> "which already exists."
        Nothing -> case Map.lookup r m of
          Nothing ->
            error . Text.unpack $
              "tried to rename `" <> r <> "` before it was declared."
          Just t -> Map.insert name t . Map.delete r $ m
      Alias r name -> case Map.lookup name m of
        Just _ ->
          error . Text.unpack $
            "tried to alias `" <> r <> "` to `" <> name <> "`, "
              <> "which already exists."
        Nothing -> case Map.lookup r m of
          Nothing ->
            error . Text.unpack $
              "tried to alias `" <> r <> "` before it was declared."
          Just t -> Map.insert name t m

termRefTypes :: Var v => Map R.Reference (Type v)
termRefTypes = foldl' go mempty builtinsSrc
  where
    go m = \case
      B r t -> Map.insert (R.Builtin r) t m
      D r t -> Map.insert (R.Builtin r) t m
      _ -> m

builtinsSrc :: Var v => [BuiltinDSL v]
builtinsSrc =
  [ B "Int.+" $ int --> int --> int,
    B "Int.-" $ int --> int --> int,
    B "Int.*" $ int --> int --> int,
    B "Int./" $ int --> int --> int,
    B "Int.<" $ int --> int --> boolean,
    B "Int.>" $ int --> int --> boolean,
    B "Int.<=" $ int --> int --> boolean,
    B "Int.>=" $ int --> int --> boolean,
    B "Int.==" $ int --> int --> boolean,
    B "Int.and" $ int --> int --> int,
    B "Int.or" $ int --> int --> int,
    B "Int.xor" $ int --> int --> int,
    B "Int.complement" $ int --> int,
    B "Int.increment" $ int --> int,
    B "Int.isEven" $ int --> boolean,
    B "Int.isOdd" $ int --> boolean,
    B "Int.signum" $ int --> int,
    B "Int.leadingZeros" $ int --> nat,
    B "Int.negate" $ int --> int,
    B "Int.mod" $ int --> int --> int,
    B "Int.pow" $ int --> nat --> int,
    B "Int.shiftLeft" $ int --> nat --> int,
    B "Int.shiftRight" $ int --> nat --> int,
    B "Int.truncate0" $ int --> nat,
    B "Int.toText" $ int --> text,
    B "Int.fromText" $ text --> optionalt int,
    B "Int.toFloat" $ int --> float,
    B "Int.trailingZeros" $ int --> nat,
    B "Int.popCount" $ int --> nat,
    B "Nat.*" $ nat --> nat --> nat,
    B "Nat.+" $ nat --> nat --> nat,
    B "Nat./" $ nat --> nat --> nat,
    B "Nat.<" $ nat --> nat --> boolean,
    B "Nat.<=" $ nat --> nat --> boolean,
    B "Nat.==" $ nat --> nat --> boolean,
    B "Nat.>" $ nat --> nat --> boolean,
    B "Nat.>=" $ nat --> nat --> boolean,
    B "Nat.and" $ nat --> nat --> nat,
    B "Nat.or" $ nat --> nat --> nat,
    B "Nat.xor" $ nat --> nat --> nat,
    B "Nat.complement" $ nat --> nat,
    B "Nat.drop" $ nat --> nat --> nat,
    B "Nat.fromText" $ text --> optionalt nat,
    B "Nat.increment" $ nat --> nat,
    B "Nat.isEven" $ nat --> boolean,
    B "Nat.isOdd" $ nat --> boolean,
    B "Nat.leadingZeros" $ nat --> nat,
    B "Nat.mod" $ nat --> nat --> nat,
    B "Nat.pow" $ nat --> nat --> nat,
    B "Nat.shiftLeft" $ nat --> nat --> nat,
    B "Nat.shiftRight" $ nat --> nat --> nat,
    B "Nat.sub" $ nat --> nat --> int,
    B "Nat.toFloat" $ nat --> float,
    B "Nat.toInt" $ nat --> int,
    B "Nat.toText" $ nat --> text,
    B "Nat.trailingZeros" $ nat --> nat,
    B "Nat.popCount" $ nat --> nat,
    B "Float.+" $ float --> float --> float,
    B "Float.-" $ float --> float --> float,
    B "Float.*" $ float --> float --> float,
    B "Float./" $ float --> float --> float,
    B "Float.<" $ float --> float --> boolean,
    B "Float.>" $ float --> float --> boolean,
    B "Float.<=" $ float --> float --> boolean,
    B "Float.>=" $ float --> float --> boolean,
    B "Float.==" $ float --> float --> boolean,
    -- Trigonmetric Functions
    B "Float.acos" $ float --> float,
    B "Float.asin" $ float --> float,
    B "Float.atan" $ float --> float,
    B "Float.atan2" $ float --> float --> float,
    B "Float.cos" $ float --> float,
    B "Float.sin" $ float --> float,
    B "Float.tan" $ float --> float,
    -- Hyperbolic Functions
    B "Float.acosh" $ float --> float,
    B "Float.asinh" $ float --> float,
    B "Float.atanh" $ float --> float,
    B "Float.cosh" $ float --> float,
    B "Float.sinh" $ float --> float,
    B "Float.tanh" $ float --> float,
    -- Exponential Functions
    B "Float.exp" $ float --> float,
    B "Float.log" $ float --> float,
    B "Float.logBase" $ float --> float --> float,
    -- Power Functions
    B "Float.pow" $ float --> float --> float,
    B "Float.sqrt" $ float --> float,
    -- Rounding and Remainder Functions
    B "Float.ceiling" $ float --> int,
    B "Float.floor" $ float --> int,
    B "Float.round" $ float --> int,
    B "Float.truncate" $ float --> int,
    -- Float Utils
    B "Float.abs" $ float --> float,
    B "Float.max" $ float --> float --> float,
    B "Float.min" $ float --> float --> float,
    B "Float.toText" $ float --> text,
    B "Float.fromText" $ text --> optionalt float,
    B "Universal.==" $ forall1 "a" (\a -> a --> a --> boolean),
    -- Don't we want a Universal.!= ?

    -- Universal.compare intended as a low level function that just returns
    -- `Int` rather than some Ordering data type. If we want, later,
    -- could provide a pure Unison wrapper for Universal.compare that
    -- returns a proper data type.
    --
    -- 0 is equal, < 0 is less than, > 0 is greater than
    B "Universal.compare" $ forall1 "a" (\a -> a --> a --> int),
    B "Universal.>" $ forall1 "a" (\a -> a --> a --> boolean),
    B "Universal.<" $ forall1 "a" (\a -> a --> a --> boolean),
    B "Universal.>=" $ forall1 "a" (\a -> a --> a --> boolean),
    B "Universal.<=" $ forall1 "a" (\a -> a --> a --> boolean),
    B "bug" $ forall1 "a" (\a -> forall1 "b" (\b -> a --> b)),
    B "todo" $ forall1 "a" (\a -> forall1 "b" (\b -> a --> b)),
    B "Boolean.not" $ boolean --> boolean,
    B "Text.empty" text,
    B "Text.++" $ text --> text --> text,
    B "Text.take" $ nat --> text --> text,
    B "Text.drop" $ nat --> text --> text,
    B "Text.size" $ text --> nat,
    B "Text.==" $ text --> text --> boolean,
    D "Text.!=" $ text --> text --> boolean,
    B "Text.<=" $ text --> text --> boolean,
    B "Text.>=" $ text --> text --> boolean,
    B "Text.<" $ text --> text --> boolean,
    B "Text.>" $ text --> text --> boolean,
    B "Text.uncons" $ text --> optionalt (tuple [char, text]),
    B "Text.unsnoc" $ text --> optionalt (tuple [text, char]),
    B "Text.toCharList" $ text --> list char,
    B "Text.fromCharList" $ list char --> text,
    B "Text.toUtf8" $ text --> bytes,
    B "Text.fromUtf8.v2" $ bytes --> eithert failure text,
    B "Char.toNat" $ char --> nat,
    B "Char.fromNat" $ nat --> char,
    B "Bytes.empty" bytes,
    B "Bytes.fromList" $ list nat --> bytes,
    B "Bytes.++" $ bytes --> bytes --> bytes,
    B "Bytes.take" $ nat --> bytes --> bytes,
    B "Bytes.drop" $ nat --> bytes --> bytes,
    B "Bytes.at" $ nat --> bytes --> optionalt nat,
    B "Bytes.toList" $ bytes --> list nat,
    B "Bytes.size" $ bytes --> nat,
    B "Bytes.flatten" $ bytes --> bytes,
    {- These are all `Bytes -> Bytes`, rather than `Bytes -> Text`.
       This is intentional: it avoids a round trip to `Text` if all
       you are doing with the bytes is dumping them to a file or a
       network socket.

       You can always `Text.fromUtf8` the results of these functions
       to get some `Text`.
     -}
    B "Bytes.toBase16" $ bytes --> bytes,
    B "Bytes.toBase32" $ bytes --> bytes,
    B "Bytes.toBase64" $ bytes --> bytes,
    B "Bytes.toBase64UrlUnpadded" $ bytes --> bytes,
    B "Bytes.fromBase16" $ bytes --> eithert text bytes,
    B "Bytes.fromBase32" $ bytes --> eithert text bytes,
    B "Bytes.fromBase64" $ bytes --> eithert text bytes,
    B "Bytes.fromBase64UrlUnpadded" $ bytes --> eithert text bytes,
    B "List.empty" $ forall1 "a" list,
    B "List.cons" $ forall1 "a" (\a -> a --> list a --> list a),
    Alias "List.cons" "List.+:",
    B "List.snoc" $ forall1 "a" (\a -> list a --> a --> list a),
    Alias "List.snoc" "List.:+",
    B "List.take" $ forall1 "a" (\a -> nat --> list a --> list a),
    B "List.drop" $ forall1 "a" (\a -> nat --> list a --> list a),
    B "List.++" $ forall1 "a" (\a -> list a --> list a --> list a),
    B "List.size" $ forall1 "a" (\a -> list a --> nat),
    B "List.at" $ forall1 "a" (\a -> nat --> list a --> optionalt a),
    B "Debug.watch" $ forall1 "a" (\a -> text --> a --> a)
  ]
    ++
    -- avoid name conflicts with Universal == < > <= >=
    [ Rename (t <> "." <> old) (t <> "." <> new)
      | t <- ["Int", "Nat", "Float", "Text"],
        (old, new) <-
          [ ("==", "eq"),
            ("<", "lt"),
            ("<=", "lteq"),
            (">", "gt"),
            (">=", "gteq")
          ]
    ]
    ++ moveUnder "io2" ioBuiltins
    ++ moveUnder "io2" mvarBuiltins
    ++ hashBuiltins
    ++ fmap (uncurry B) codeBuiltins

moveUnder :: Text -> [(Text, Type v)] -> [BuiltinDSL v]
moveUnder prefix bs = bs >>= \(n, ty) -> [B n ty, Rename n (prefix <> "." <> n)]

-- builtins which have a version appended to their name (like the .v2 in IO.putBytes.v2)
-- Should be renamed to not have the version suffix
stripVersion :: [BuiltinDSL v] -> [BuiltinDSL v]
stripVersion bs =
  bs >>= rename
  where
    rename :: BuiltinDSL v -> [BuiltinDSL v]
    rename o@(B n _) = renameB o $ RE.matchOnceText regex n
    rename o@(Rename _ _) = [renameRename o]
    rename o = [o]

    -- When we see a B declaraiton, we add an additional Rename in the
    -- stream to rename it if it ahs a version string
    renameB :: BuiltinDSL v -> Maybe (Text, RE.MatchText Text, Text) -> [BuiltinDSL v]
    renameB o@(B n _) (Just (before, _, _)) = [o, Rename n before]
    renameB (Rename n _) (Just (before, _, _)) = [Rename n before]
    renameB x _ = [x]

    -- if there is already a Rename in the stream, then both sides of the
    -- rename need to have version stripped. This happens in when we move
    -- builtin IO to the io2 namespace, we might end up with:
    -- [ B IO.putBytes.v2 _, Rename IO.putBytes.v2 io2.IO.putBytes.v2]
    -- and would be become:
    -- [ B IO.putBytes.v2 _, Rename IO.putBytes.v2 IO.putBytes, Rename IO.putBytes io2.IO.putBytes ]
    renameRename :: BuiltinDSL v -> BuiltinDSL v
    renameRename (Rename before1 before2) =
      let after1 = renamed before1 (RE.matchOnceText regex before1)
          after2 = renamed before2 (RE.matchOnceText regex before2)
       in Rename after1 after2
    renameRename x = x

    renamed :: Text -> Maybe (Text, RE.MatchText Text, Text) -> Text
    renamed _ (Just (before, _, _)) = before
    renamed x _ = x

    r :: String
    r = "\\.v[0-9]+"
    regex :: RE.Regex
    regex = RE.makeRegexOpts (RE.defaultCompOpt {RE.caseSensitive = False}) RE.defaultExecOpt r

hashBuiltins :: Var v => [BuiltinDSL v]
hashBuiltins =
  [ B "crypto.hash" $ forall1 "a" (\a -> hashAlgo --> a --> bytes),
    B "crypto.hashBytes" $ hashAlgo --> bytes --> bytes,
    B "crypto.hmac" $ forall1 "a" (\a -> hashAlgo --> bytes --> a --> bytes),
    B "crypto.hmacBytes" $ hashAlgo --> bytes --> bytes --> bytes
  ]
    ++ map h ["Sha3_512", "Sha3_256", "Sha2_512", "Sha2_256", "Blake2b_512", "Blake2b_256", "Blake2s_256"]
  where
    hashAlgo = Type.ref () Type.hashAlgorithmRef
    h name = B ("crypto.HashAlgorithm." <> name) hashAlgo

ioBuiltins :: Var v => [(Text, Type v)]
ioBuiltins =
  [ ("IO.openFile.v2", text --> fmode --> iof handle),
    ("IO.closeFile.v2", handle --> iof unit),
    ("IO.isFileEOF.v2", handle --> iof boolean),
    ("IO.isFileOpen.v2", handle --> iof boolean),
    ("IO.isSeekable.v2", handle --> iof boolean),
    ("IO.seekHandle.v2", handle --> smode --> int --> iof unit),
    ("IO.handlePosition.v2", handle --> iof int),
    ("IO.getBuffering.v2", handle --> iof bmode),
    ("IO.setBuffering.v2", handle --> bmode --> iof unit),
    ("IO.getBytes.v2", handle --> nat --> iof bytes),
    ("IO.putBytes.v2", handle --> bytes --> iof unit),
    ("IO.systemTime.v2", unit --> iof nat),
    ("IO.getTempDirectory.v2", unit --> iof text),
    ("IO.createTempDirectory", text --> iof text),
    ("IO.getCurrentDirectory.v2", unit --> iof text),
    ("IO.setCurrentDirectory.v2", text --> iof unit),
    ("IO.fileExists.v2", text --> iof boolean),
    ("IO.isDirectory.v2", text --> iof boolean),
    ("IO.createDirectory.v2", text --> iof unit),
    ("IO.removeDirectory.v2", text --> iof unit),
    ("IO.renameDirectory.v2", text --> text --> iof unit),
    ("IO.removeFile.v2", text --> iof unit),
    ("IO.renameFile.v2", text --> text --> iof unit),
    ("IO.getFileTimestamp.v2", text --> iof nat),
    ("IO.getFileSize.v2", text --> iof nat),
    ("IO.serverSocket.v2", text --> text --> iof socket),
    ("IO.listen.v2", socket --> iof unit),
    ("IO.clientSocket.v2", text --> text --> iof socket),
    ("IO.closeSocket.v2", socket --> iof unit),
    ("IO.socketAccept.v2", socket --> iof socket),
    ("IO.socketSend.v2", socket --> bytes --> iof unit),
    ("IO.socketReceive.v2", socket --> nat --> iof bytes),
    ( "IO.forkComp.v2",
      forall1 "a" $ \a -> (unit --> iof a) --> io threadId
    ),
    ("IO.stdHandle", stdhandle --> handle),
    ("IO.delay.v2", nat --> iof unit),
    ("IO.kill.v2", threadId --> iof unit),
    ("Tls.newClient", tlsClientConfig --> socket --> iof tls),
    ("Tls.newServer", tlsServerConfig --> socket --> iof tls),
    ("Tls.handshake", tls --> iof unit),
    ("Tls.send", tls --> bytes --> iof unit),
    ("Tls.receive", tls --> iof bytes),
    ("Tls.terminate", tls --> iof unit),
    ("Tls.Config.defaultClient", text --> bytes --> tlsClientConfig),
    ("Tls.Config.defaultServer", tlsServerConfig)
  ]

mvarBuiltins :: forall v. Var v => [(Text, Type v)]
mvarBuiltins =
  [ ("MVar.new", forall1 "a" $ \a -> a --> io (mvar a)),
    ("MVar.newEmpty.v2", forall1 "a" $ \a -> unit --> io (mvar a)),
    ("MVar.take.v2", forall1 "a" $ \a -> mvar a --> iof a),
    ("MVar.tryTake", forall1 "a" $ \a -> mvar a --> io (optionalt a)),
    ("MVar.put.v2", forall1 "a" $ \a -> mvar a --> a --> iof unit),
    ("MVar.tryPut", forall1 "a" $ \a -> mvar a --> a --> io boolean),
    ("MVar.swap.v2", forall1 "a" $ \a -> mvar a --> a --> iof a),
    ("MVar.isEmpty", forall1 "a" $ \a -> mvar a --> io boolean),
    ("MVar.read.v2", forall1 "a" $ \a -> mvar a --> iof a),
    ("MVar.tryRead", forall1 "a" $ \a -> mvar a --> io (optionalt a))
  ]
  where
    mvar :: Type v -> Type v
    mvar a = Type.ref () Type.mvarRef `app` a

codeBuiltins :: forall v. Var v => [(Text, Type v)]
codeBuiltins =
  [ ("Code.dependencies", code --> list termLink),
    ("Code.isMissing", termLink --> io boolean),
    ("Code.serialize", code --> bytes),
    ("Code.deserialize", bytes --> eithert text code),
    ("Code.cache_", list (tuple [termLink, code]) --> io (list termLink)),
    ("Code.lookup", termLink --> io (optionalt code)),
    ("Value.dependencies", value --> list termLink),
    ("Value.serialize", value --> bytes),
    ("Value.deserialize", bytes --> eithert text value),
    ("Value.value", forall1 "a" $ \a -> a --> value),
    ( "Value.load",
      forall1 "a" $ \a -> value --> io (eithert (list termLink) a)
    )
  ]

forall1 :: Var v => Text -> (Type v -> Type v) -> Type v
forall1 name body =
  let a = Var.named name
   in Type.forall () a (body $ Type.var () a)

app :: Ord v => Type v -> Type v -> Type v
app = Type.app ()

list :: Ord v => Type v -> Type v
list arg = Type.vector () `app` arg

optionalt :: Ord v => Type v -> Type v
optionalt arg = DD.optionalType () `app` arg

tuple :: Ord v => [Type v] -> Type v
tuple [t] = t
tuple ts = foldr pair (DD.unitType ()) ts

pair :: Ord v => Type v -> Type v -> Type v
pair l r = DD.pairType () `app` l `app` r

(-->) :: Ord v => Type v -> Type v -> Type v
a --> b = Type.arrow () a b

infixr 9 -->

io, iof :: Var v => Type v -> Type v
io = Type.effect1 () (Type.builtinIO ())
iof = io . eithert failure

failure :: Var v => Type v
failure = DD.failureType ()

eithert :: Var v => Type v -> Type v -> Type v
eithert l r = DD.eitherType () `app` l `app` r

socket, threadId, handle, unit :: Var v => Type v
socket = Type.socket ()
threadId = Type.threadId ()
handle = Type.fileHandle ()
unit = DD.unitType ()

tls, tlsClientConfig, tlsServerConfig :: Var v => Type v
tls = Type.ref () Type.tlsRef
tlsClientConfig = Type.ref () Type.tlsClientConfigRef
tlsServerConfig = Type.ref () Type.tlsServerConfigRef

-- tlsVersion = Type.ref () Type.tlsVersionRef
-- tlsCiphers = Type.ref () Type.tlsCiphersRef

fmode, bmode, smode, stdhandle :: Var v => Type v
fmode = DD.fileModeType ()
bmode = DD.bufferModeType ()
smode = DD.seekModeType ()
stdhandle = DD.stdHandleType ()

int, nat, bytes, text, boolean, float, char :: Var v => Type v
int = Type.int ()
nat = Type.nat ()
bytes = Type.bytes ()
text = Type.text ()
boolean = Type.boolean ()
float = Type.float ()
char = Type.char ()

code, value, termLink :: Var v => Type v
code = Type.code ()
value = Type.value ()
termLink = Type.termLink ()
