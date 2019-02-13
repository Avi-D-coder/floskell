{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Test the pretty printer.
module Main where

import           Control.Monad                ( forM_, guard )

import           Data.ByteString.Lazy         ( ByteString )
import qualified Data.ByteString.Lazy         as L
import qualified Data.ByteString.Lazy.Builder as B
import qualified Data.ByteString.Lazy.UTF8    as UTF8
import           Data.Maybe                   ( mapMaybe )
import qualified Data.Text                    as T

import           Floskell

import           Language.Haskell.Exts        ( Language(Haskell2010) )

import           Markdone                     ( Markdone(..) )
import qualified Markdone                     as MD

import           System.Environment           ( getArgs )

import           Test.Hspec

data TestTree =
    TestSection String [TestTree] | TestSnippet ByteString | TestMismatchMarker

-- | Prints a string without quoting and escaping.
newtype Readable = Readable ByteString
    deriving ( Eq )

instance Show Readable where
    show (Readable x) = "\n" ++ UTF8.toString x

-- | Version of 'shouldBe' that prints strings in a readable way,
-- better for our use-case.
shouldBeReadable :: ByteString -> ByteString -> Expectation
shouldBeReadable x y = Readable x `shouldBe` Readable y

haskell :: ByteString
haskell = "haskell"

referenceFile :: Style -> String
referenceFile style = "styles/" ++ name ++ ".md"
  where
    name = T.unpack $ styleName style

loadMarkdone :: String -> IO [Markdone]
loadMarkdone filename = do
    bytes <- L.readFile filename
    MD.parse (MD.tokenize bytes)

saveMarkdone :: String -> [Markdone] -> IO ()
saveMarkdone filename doc =
    L.writeFile filename . B.toLazyByteString $ MD.print doc

-- | Extract code snippets from a Markdone document.
extractSnippets :: ByteString -> [Markdone] -> [TestTree]
extractSnippets lang = mapMaybe convert
  where
    convert (Section name children) =
        return $ TestSection (UTF8.toString name) $
        extractSnippets lang children
    convert (CodeFence l c) = do
        guard $ l == lang
        return $ TestSnippet c
    convert _ = Nothing

-- | Load haskell code snippets from Markdone document.
loadSnippets :: String -> IO [TestTree]
loadSnippets filename = do
    doc <- loadMarkdone filename
    return $ extractSnippets haskell doc

-- | Some styles are broken and will fail the idempotency test.
expectedFailures :: [(T.Text, [Int])]
expectedFailures = []

-- | Convert the Markdone document to Spec benchmarks.
toSpec :: Style -> [Int] -> [TestTree] -> [TestTree] -> Spec
toSpec style path inp ref =
    forM_ (zip3 [ 1 :: Int .. ] inp (ref ++ repeat TestMismatchMarker)) $ \case
        (n, TestSection title children, TestSection _ children') ->
            describe title $ toSpec style (path ++ [ n ]) children children'
        (n, TestSnippet code, TestSnippet code') -> do
            let path' = (styleName style, path ++ [ n ])
            it (name n "formats as expected") $
                case reformatSnippet style code of
                    Left e -> error e
                    Right b -> b `shouldBeReadable` code'
            it (name n "formatting is idempotent") $
                if path' `elem` expectedFailures
                then pending
                else case reformatSnippet style
                                          code >>= reformatSnippet style of
                    Left e -> error e
                    Right b -> b `shouldBeReadable` code'
        (n, _, _) -> error $ name n "structure mismatch in reference file"
  where
    name n desc = "Snippet " ++ show n ++ " - " ++ desc

-- | Main tests.
testAll :: IO ()
testAll = do
    input <- loadSnippets "TEST.md"
    refs <- mapM loadRef styles
    hspec $ forM_ refs $
        \(name, style, ref) -> context name $ toSpec style [] input ref
  where
    loadRef style = do
        let name = T.unpack $ styleName style
        tree <- loadSnippets $ referenceFile style
        return (name, style, tree)

reformatSnippet :: Style -> ByteString -> Either String ByteString
reformatSnippet style =
    reformat (AppConfig style Haskell2010 defaultExtensions) (Just "TEST.md")

regenerate :: Style -> [Markdone] -> [Markdone]
regenerate style = map fmt
  where
    fmt (CodeFence lang code) =
        if lang == haskell
        then CodeFence lang $ either (UTF8.fromString . ("-- " ++) . show) id $
            reformatSnippet style code
        else CodeFence lang code
    fmt (Section heading children) =
        Section heading $ regenerate style children
    fmt x = x

-- | Regenerate style reference files.
regenerateAll :: IO ()
regenerateAll = do
    doc <- loadMarkdone "TEST.md"
    forM_ styles $ \style -> saveMarkdone (referenceFile style) $
        regenerate style doc

main :: IO ()
main = do
    args <- getArgs
    case args of
        [ "regenerate" ] -> regenerateAll
        _ -> testAll
