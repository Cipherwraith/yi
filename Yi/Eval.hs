{-# LANGUAGE PatternSignatures #-}

module Yi.Eval (
        -- * Eval\/Interpretation
        jumpToErrorE,
        jumpToE,
        consoleKeymap,
        execEditorAction
) where

import Control.Monad
import Data.Array
import Data.List
import Prelude hiding (error)
import Yi.Regex
import Yi.Config
import Yi.Core
import Yi.Keymap
import Yi.Interact hiding (write)
import Yi.Event
import Yi.Buffer
import Yi.Buffer.Region
import Yi.Buffer.HighLevel
import Yi.Dired
import Yi.Interpreter
import Data.Dynamic
import Control.Monad.Reader (asks)
import Yi.Editor
import Yi.MiniBuffer () -- instances

jumpToE :: String -> Int -> Int -> YiM ()
jumpToE filename line column = do
  fnewE filename
  withBuffer $ do gotoLn line
                  moveXorEol column

errorRegex :: Regex
errorRegex = makeRegex "^(.+):([0-9]+):([0-9]+):.*$"

parseErrorMessage :: String -> Maybe (String, Int, Int)
parseErrorMessage ln = do
  (_,result,_) <- matchOnceText errorRegex ln
  let [_,file,line,col] = take 3 $ map fst $ elems result
  return (file, read line, read col)

parseErrorMessageB :: BufferM (String, Int, Int)
parseErrorMessageB = do
  ln <- readLnB
  let Just location = parseErrorMessage ln
  return location

jumpToErrorE :: YiM ()
jumpToErrorE = do
  (f,l,c) <- withBuffer parseErrorMessageB
  jumpToE f l c

prompt :: String
prompt = "Yi> "

takeCommand :: String -> String
takeCommand x | prompt `isPrefixOf` x = drop (length prompt) x
              | otherwise = x

consoleKeymap :: Keymap
consoleKeymap = do event (Event KEnter [])
                   write $ do x <- withBuffer readLnB
                              case parseErrorMessage x of
                                Just (f,l,c) -> jumpToE f l c
                                Nothing -> do withBuffer $ do
                                                p <- pointB
                                                botB
                                                p' <- pointB
                                                when (p /= p') $
                                                   insertN ("\n" ++ prompt ++ takeCommand x)
                                                insertN "\n"
                                                pt <- pointB
                                                insertN prompt
                                                bm <- getBookmarkB "errorInsert"
                                                setMarkPointB bm pt
                                              execEditorAction $ takeCommand x

execEditorAction :: String -> YiM ()
execEditorAction s = do 
  env <- asks (publishedActions . yiConfig)
  case toMono =<< interpret =<< addMakeAction =<< rename env =<< parse s of
    Left err -> errorEditor err
    Right a -> runAction a
  where addMakeAction expr = return $ UApp (UVal mkAct) expr
        mkAct = [
                 toDyn (makeAction :: BufferM () -> Action),
                 toDyn (makeAction :: BufferM Bool -> Action),
                 toDyn (makeAction :: BufferM Int -> Action),
                 toDyn (makeAction :: BufferM String -> Action),
                 toDyn (makeAction :: BufferM Region -> Action),

                 toDyn (makeAction :: (String -> BufferM ()) -> Action),

                 toDyn (makeAction :: EditorM () -> Action),

                 toDyn (makeAction :: YiM () -> Action),
                 toDyn (makeAction :: (String -> YiM ()) -> Action)
                ]
            
