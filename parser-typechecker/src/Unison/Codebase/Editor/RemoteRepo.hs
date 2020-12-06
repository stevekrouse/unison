{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Unison.Codebase.Editor.RemoteRepo where

import Data.Text as Text
import Unison.Codebase.Path (Path)
import qualified Unison.Codebase.Path as Path
import Unison.Codebase.ShortBranchHash (ShortBranchHash)
import qualified Unison.Codebase.ShortBranchHash as SBH
import Unison.Util.Monoid as Monoid

data RemoteRepo = GitRepo {url :: Text, commit :: Maybe Text}
  deriving (Eq, Ord, Show)

printRepo :: RemoteRepo -> Text
printRepo GitRepo {..} = url <> Monoid.fromMaybe (Text.cons ':' <$> commit)

printNamespace :: RemoteRepo -> Maybe ShortBranchHash -> Path -> Text
printNamespace repo sbh path =
  printRepo repo <> case sbh of
    Nothing ->
      if path == Path.empty
        then mempty
        else ":." <> Path.toText path
    Just sbh ->
      ":#" <> SBH.toText sbh
        <> if path == Path.empty
          then mempty
          else "." <> Path.toText path

printHead :: RemoteRepo -> Path -> Text
printHead repo path = printNamespace repo Nothing path

type RemoteNamespace = (RemoteRepo, Maybe ShortBranchHash, Path)

type RemoteHead = (RemoteRepo, Path)
