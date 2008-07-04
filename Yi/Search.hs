{-# LANGUAGE DeriveDataTypeable, GeneralizedNewtypeDeriving #-}

-- Copyright (c) Tuomo Valkonen 2004.
-- Copyright (c) 2005, 2008 Don Stewart - http://www.cse.unsw.edu.au/~dons
-- Copyright (c) 2007 Jean-Philippe Bernardy

-- | Search/Replace functions

module Yi.Search (
        setRegexE,      -- :: SearchExp -> EditorM ()
        getRegexE,      -- :: EditorM (Maybe SearchExp)
        SearchMatch,
        SearchExp,
        SearchF(..),
        searchAndRepLocal,  -- :: String -> String -> IO Bool
        doSearch,            -- :: (Maybe String) -> [SearchF]
                            -- -> Direction -> YiM ()
        searchInit,        -- :: String
                            -- -> [SearchF]
                            -- -> IO SearchExp
        continueSearch,          -- :: SearchExp
                            -- -> Direction
                            -- -> IO SearchResult

        -- * Incremental Search

        isearchInitE,
        isearchIsEmpty,
        isearchAddE,
        isearchPrevE,
        isearchNextE,
        isearchWordE,
        isearchHistory,
        isearchDelE,
        isearchCancelE,
        isearchFinishE,

        -- * Replace
        qrNext,
        qrReplaceOne

                 ) where

import Prelude ()
import Yi.Prelude
import Yi.Buffer
import Yi.Buffer.HighLevel
import Yi.Regex  ( Regex, compExtended, compIgnoreCase, compNewline, makeRegexOptsM, execBlank )
import Yi.Editor
import qualified Yi.Editor as Editor

import Data.Bits ( (.|.) )
import Data.Char
import Data.Maybe
import Data.List hiding (elem)
import Data.Typeable

import Control.Monad.State

import Yi.Core
import Yi.Style
import Yi.History

-- ---------------------------------------------------------------------
-- Searching and substitutions with regular expressions
--
-- The most recent regex is held by the editor. You can get at it with
-- getRegeE. This is useful to determine if there was a previous
-- pattern.
--

-- | Put regex into regex 'register'
setRegexE :: SearchExp -> EditorM ()
setRegexE re = modify $ \e -> e { regex = Just re }

-- Return contents of regex register
getRegexE :: EditorM (Maybe SearchExp)
getRegexE = gets regex


-- ---------------------------------------------------------------------
--
-- | Global searching. Search for regex and move point to that position.
-- @Nothing@ means reuse the last regular expression. @Just s@ means use
-- @s@ as the new regular expression. Direction of search can be
-- specified as either @Backward@ or @Forward@ (forwards in the buffer).
-- Arguments to modify the compiled regular expression can be supplied
-- as well.
--

--
-- What would be interesting would be to implement our own general
-- mechanism to allow users to supply a regex function of any kind, and
-- search with that. This removes the restriction on strings be valid
-- under regex(3).
--

data SearchF = Basic        -- ^ Use non-modern (i.e. basic) regexes
             | IgnoreCase   -- ^ Compile for matching that ignores char case
             | NoNewLine    -- ^ Compile for newline-insensitive matching
    deriving Eq

type SearchMatch = (Point, Point) -- ^ beginning and end point of the match. FIXME: use region.
type SearchResult = Maybe (Either SearchMatch SearchMatch)
type SearchExp = (String, Regex)

doSearch :: (Maybe String)       -- ^ @Nothing@ means used previous
                                -- pattern, if any. Complain otherwise.
                                -- Use getRegexE to check for previous patterns
        -> [SearchF]            -- ^ Flags to modify the compiled regex
        -> Direction            -- ^ @Backward@ or @Forward@
        -> EditorM ()

doSearch s fs d =
     case s of
        Just re -> searchInit re fs >>= (flip continueSearch) d >>= f
        Nothing -> do
            mre <- getRegexE
            case mre of
                Nothing -> fail "No previous search pattern" -- NB
                Just r -> continueSearch r d >>= f
    where
        f mp = case mp of
            Just (Right _) -> return ()
            Just (Left  _) -> printMsg "Search wrapped"
            Nothing        -> fail "Pattern not found"


continueSearch :: SearchExp
          -> Direction
          -> EditorM SearchResult

continueSearch _ Backward = do
        fail "Backward searching is unimplemented"
continueSearch (s, re) _ = withBuffer0 $ searchF s re

--
-- Set up a search.
--
searchInit :: String -> [SearchF] -> EditorM SearchExp
searchInit re fs = do
    let Just c_re = makeRegexOptsM (extended .|. igcase .|. newline) execBlank re
        p = (re,c_re)
    setRegexE p
    return p

    where
        extended | Basic      `elem` fs = 0
                 | otherwise            = compExtended   -- extended regex dflt
        igcase   | IgnoreCase `elem` fs = compIgnoreCase
                 | otherwise            = 0              -- case insensitive dflt
        newline  | NoNewLine  `elem` fs = 0
                 | otherwise            = compNewline    -- newline is special


-- ---------------------------------------------------------------------
-- Internal

--
-- | Do a forward search, placing cursor at first char of pattern, if found.
-- Keymaps may implement their own regex language. How do we provide for this?
-- Also, what's happening with ^ not matching sol?
--
searchF :: String -> Regex -> BufferM SearchResult
searchF _ c_re = do
    mp <- do
            p   <- pointB
            rightB               -- start immed. after cursor
            mp  <- regexB c_re
            case fmap Right mp of
                x@(Just _) -> return x
                _ -> do moveTo 0
                        np <- regexB c_re
                        moveTo p
                        return (fmap Left np)
    case mp of
        Just (Right (p,_)) -> moveTo p
        Just (Left  (p,_)) -> moveTo p
        _                  -> return ()
    return mp

------------------------------------------------------------------------
-- Global search and replace
--


------------------------------------------------------------------------
-- | Search and replace /on current line/. Returns Bool indicating
-- success or failure
--
-- TODO too complex.
--
searchAndRepLocal :: String -> String -> EditorM Bool
searchAndRepLocal [] _ = return False   -- hmm...
searchAndRepLocal re str = do
    let Just c_re = makeRegexOptsM compExtended execBlank re
    setRegexE (re,c_re)     -- store away for later use

    mp <- withBuffer0 $ do   -- find the regex
            mp <- regexB c_re
            return mp
    case mp of
        Just (i,j) -> withBuffer0 $ do
                p  <- pointB      -- all buffer-level atm
                moveToEol
                ep <- pointB      -- eol point of current line
                moveTo i
                moveToEol
                eq <- pointB      -- eol of matched line
                moveTo p          -- go home. sub doesn't move
                if (ep /= eq)       -- then match isn't on current line
                    then return False
                    else do         -- do the replacement
                moveTo i
                deleteNBytes Forward (j ~- i) =<< pointB
                insertN str
                moveTo p          -- and back to where we were!
                return True -- signal success
        Nothing -> return False


--------------------------
-- Incremental search


newtype Isearch = Isearch [(String, Point, Direction)] deriving Typeable
-- This contains: (string currently searched, position where we
-- searched it, direction, overlay for highlighting searched text)

-- Maybe this should not be saved in a Dynamic component!
-- it could also be embedded in the Keymap state.

instance Initializable Isearch where
    initial = (Isearch [])

isearchInitE :: Direction -> EditorM ()
isearchInitE dir = do
  historyStartGen iSearch
  p <- withBuffer0 pointB
  setDynamic (Isearch [("",p,dir)])
  printMsg "I-search: "

isearchIsEmpty :: EditorM Bool
isearchIsEmpty = do
  Isearch s <- getDynamic
  return $ not $ null $ fst4 $ head $ s
      where fst4 (x,_,_) = x

isearchAddE :: String -> EditorM ()
isearchAddE increment = isearchFunE (++ increment)

isearchFunE :: (String -> String) -> EditorM ()
isearchFunE fun = do
  Isearch s <- getDynamic
  let (previous,p0,direction) = head s
  let current = fun previous
  printMsg $ "I-search: " ++ current
  prevPoint <- withBuffer0 pointB
  withBuffer0 $ do
    delOverlayLayerB HintLayer
    moveTo p0
  mp <- withBuffer0 $ searchB direction current
  case mp of
    Nothing -> do withBuffer0 $ moveTo prevPoint -- go back to where we were
                  setDynamic $ Isearch ((current,p0,direction):s)
                  printMsg $ "Failing I-search: " ++ current
    Just p -> do  let p2 = p +~ utf8Size current
                      ov = mkOverlay HintLayer p p2 (hintStyle)
                  withBuffer0 $ do
                    moveTo p2
                    addOverlayB ov
                  setDynamic $ Isearch ((current,p,direction):s)
                 
isearchDelE :: EditorM ()
isearchDelE = do
  Isearch s <- getDynamic
  case s of
    ((_,_,_):(text,p,dir):rest) -> do
      let p2 = p +~ utf8Size text
          ov = mkOverlay HintLayer p p2 (hintStyle)
      withBuffer0 $ do
        moveTo p2
        delOverlayLayerB HintLayer
        addOverlayB ov
      setDynamic $ Isearch ((text,p,dir):rest)
      printMsg $ "I-search: " ++ text
    _ -> return () -- if the searched string is empty, don't try to remove chars from it.

isearchHistory :: Int -> EditorM ()
isearchHistory delta = do
  Isearch ((current,_p0,_dir):_) <- getDynamic
  h <- historyMoveGen iSearch delta (return current)
  isearchFunE (const h)

isearchPrevE :: EditorM ()
isearchPrevE = isearchNext0 Backward

isearchNextE :: EditorM ()
isearchNextE = isearchNext0 Forward

isearchNext0 :: Direction -> EditorM ()
isearchNext0 newDir = do
  Isearch ((current,_p0,_dir):_rest) <- getDynamic
  if null current
    then isearchHistory 1
    else isearchNext newDir
     

isearchNext :: Direction -> EditorM ()
isearchNext direction = do
  Isearch ((current,p0,_dir):rest) <- getDynamic
  withBuffer0 $ moveTo (p0 + startOfs)
  mp <- withBuffer0 $ do
    searchB direction current
  case mp of
    Nothing -> do endPoint <- withBuffer0 $ do 
                          moveTo (p0 +~ utf8Size current) -- revert to offset we were before.
                          sizeB   
                  printMsg $ "isearch: end of document reached"
                  let wrappedOfs = case direction of
                                     Forward -> 0
                                     Backward -> endPoint
                  setDynamic $ Isearch ((current,wrappedOfs,direction):rest) -- prepare to wrap around.
    Just p -> do  let p2 = p +~ utf8Size current
                      ov = mkOverlay HintLayer p p2 hintStyle
                  withBuffer0 $ do
                    moveTo p2
                    delOverlayLayerB HintLayer
                    addOverlayB ov
                  setDynamic $ Isearch ((current,p,direction):rest)
 where startOfs = case direction of
                      Forward  ->  1
                      Backward -> -1

isearchWordE :: EditorM ()
isearchWordE = do
  text <- withBuffer0 (pointB >>= nelemsB 32) -- add maximum 32 chars at a time.
  let (prefix, rest) = span (not . isAlpha) text
      word = takeWhile isAlpha rest
  isearchAddE (prefix ++ word)

isearchFinishE :: EditorM ()
isearchFinishE = isearchEnd True

isearchCancelE :: EditorM ()
isearchCancelE = isearchEnd False

iSearch :: String
iSearch = "isearch"

isearchEnd :: Bool -> EditorM ()
isearchEnd accept = do
  Isearch s <- getDynamic
  let (lastSearched,_,_) = head s
  let (_,p0,_) = last s
  withBuffer0 $ delOverlayLayerB HintLayer
  historyFinishGen iSearch (return lastSearched)
  if accept 
     then do withBuffer0 $ setSelectionMarkPointB p0 
             printMsg "Quit"
     else withBuffer0 $ moveTo p0
  
  

-----------------
-- Query-Replace

qrNext :: BufferRef -> String -> YiM ()
qrNext b what = do
  mp <- withGivenBuffer b $ searchB Forward what
  case mp of
    Nothing -> do
            withEditor $ printMsg "String to search not found"
            closeWindow
    Just p -> withGivenBuffer b $ do
                   m <- getSelectionMarkB
                   moveTo (p +~ utf8Size what)
                   setMarkPointB m p


qrReplaceOne :: BufferRef -> String -> String -> YiM ()
qrReplaceOne b what replacement = do
  withGivenBuffer b $ do
    deleteN (length what)
    insertN replacement
  qrNext b what

