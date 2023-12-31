module UI
  ( run
  ) where

import           Brick                  (App (..), AttrName, BrickEvent (..),
                                         EventM, Location (..), Next,
                                         Padding (..), Widget, attrMap,
                                         attrName, continue, defaultMain,
                                         emptyWidget, fg, halt, padAll,
                                         padBottom, showCursor, showFirstCursor,
                                         str, withAttr, (<+>), (<=>), vBox, padTop, customMain)
import           Brick.Widgets.Center   (center, vCenterWith, hCenterWith)
import           Control.Monad.IO.Class (liftIO)
import           Data.Char              (isSpace)
import           Data.Maybe             (fromMaybe)
import           Data.Time              (getCurrentTime, addUTCTime, secondsToDiffTime, secondsToNominalDiffTime, diffUTCTime, UTCTime, nominalDiffTimeToSeconds)
import           Data.Word              (Word8)
import           Graphics.Vty           (Attr, Color (..), Event (..), Key (..),
                                         Modifier (..), bold, defAttr,
                                         withStyle, mkVty)
import           Text.Printf            (printf)

import           Typeracer
import           Lib
import Brick.Widgets.Core
import qualified Brick.BChan
import qualified Graphics.Vty.Config as Graphics.Vty
import Control.Concurrent (ThreadId, forkIO, threadDelay, MVar)
import Control.Concurrent.MVar ( newEmptyMVar, takeMVar, putMVar )
import Data.Fixed (div')
import GHC.IO.Unsafe (unsafePerformIO)

import           Data.Text           (Text)
import qualified Data.Text           as T
import qualified Data.Text.IO        as T


hitAttrName :: AttrName
hitAttrName = attrName "hit"

emptyAttrName :: AttrName
emptyAttrName = attrName "empty"

errorAttrName :: AttrName
errorAttrName = attrName "error"

resultAttrName :: AttrName
resultAttrName = attrName "result"

drawCharacter :: Character -> Widget ()
drawCharacter (Hit c)    = withAttr hitAttrName $ str [c]
drawCharacter (Miss ' ') = withAttr errorAttrName $ str ['_']
drawCharacter (Miss c)   = withAttr errorAttrName $ str [c]
drawCharacter (Empty c)  = withAttr emptyAttrName $ str [c]

drawLine :: Line -> Widget ()
-- We display an empty line as a single space so that it still occupies
-- vertical space.
drawLine [] = str " "
drawLine ls = foldl1 (<+>) $ map drawCharacter ls

drawText :: State -> Widget ()
drawText s = padBottom (Pad 2) . foldl (<=>) emptyWidget . map drawLine $ page s

drawResults :: State -> Widget ()
drawResults s =
  withAttr resultAttrName . str $
  printf "%.d words per minute • %.f%% accuracy \nPress Enter to play again • Escape to quit." (finalWpm s) (accuracy s * 100)

drawStartCountdown :: State -> Widget ()
drawStartCountdown s = countdown
  where 
    countdown =
      let originalStartTime = addUTCTime (-(secondsToNominalDiffTime $ fromIntegral $ howMuchOnCounter s)) (gameStartTime s)
          durationTime = diffUTCTime (gameStartTime s) originalStartTime
          elapsedTime = diffUTCTime (currentTime s) originalStartTime

          -- trashy math to get a counter to go from howMuchOnCounter - 1, ugh...
          elapsed = realToFrac (nominalDiffTimeToSeconds elapsedTime) :: Double
          duration = realToFrac (nominalDiffTimeToSeconds durationTime) :: Double
          counterNum = 1 + howMuchOnCounter s - ceiling (fromIntegral (howMuchOnCounter s) * (elapsed / duration))
      in 
        -- Just in case we render too quickly
        if counterNum == 0 || hasGameStarted s then 
          hBox [withAttr hitAttrName $ asciiThing "3", withAttr hitAttrName $ asciiThing "2", withAttr hitAttrName $ asciiThing "1", withAttr hitAttrName $ asciiThing "GO!"]
        else if counterNum < 0 || counterNum > howMuchOnCounter s then 
          str " "
        else if counterNum == 3 then
          withAttr errorAttrName $ asciiThing "3"
        else if counterNum == 2 then 
          hBox [withAttr errorAttrName $ asciiThing "3", withAttr errorAttrName $ asciiThing "2"]
        else 
          hBox [withAttr errorAttrName $ asciiThing "3", withAttr errorAttrName $ asciiThing "2", withAttr errorAttrName $ asciiThing "1"]
    asciiThing x = str ("._______.\n" ++ "|       |\n" ++ (padString 8 ("|   " ++ x)) ++ "|\n" ++ "|_______|")

-- computeCarPadding will take the percent completion the user is and multiply by the width of
-- the terminal space. So when the user is done, we'll be at 100%
computeCarPadding :: State -> Player -> Int -> Int
computeCarPadding s p trueWidth = ceiling (completionPercent s p * fromIntegral trueWidth)

drawPlayerLabel :: State -> String -> Player -> Widget ()
drawPlayerLabel s name p = case isWinner s p of
  True -> vCenterWith Nothing (vBox [str "WINNER", str name, str $ padString 8 $ show wpm ++ " wpm"])
  False -> vCenterWith Nothing (vBox [str name, str $ padString 8 $ show wpm ++ " wpm"])
  where
    wpm = unsafePerformIO $ currentWpm s p

drawCar :: State -> Player -> Widget ()
drawCar s p = let trueWidth = screenWidth s - carWidth s
                  leftPad = computeCarPadding s p trueWidth
                  rightPad = screenWidth s - leftPad - carWidth s in
  vCenterWith Nothing . bottomDottedBorder (screenWidth s) . padRight (Pad rightPad) . padLeft (Pad leftPad) $ str $ car s

drawPlayer :: State -> String -> Player -> Widget ()
drawPlayer s name p = hBox [drawCar s p, drawPlayerLabel s name p]

draw :: State -> [Widget ()]
draw s
  | hasEnded s = pure . center . padAll 1 . vBox $ [topRow s, drawText s, drawResults s]
  | otherwise =
    pure . center . padAll 1 . vBox $ [topRow s, showCursor () (Location $ cursor s) $ drawText s <=> str " "]
  where topRow s = vBox [drawStartCountdown s, drawPlayer s "(You)" (me s), drawPlayer s "(CPU)" (cpu s)]

handleChar :: Char -> State -> EventM () (Next State)
handleChar c s
  | not $ hasGameStarted s = do
    -- ignore character if game hasn't started yet
    continue s
  | isComplete s' = do
    now <- liftIO getCurrentTime
    continue $ stopClock now s'
  | otherwise =
    continue s'
  where
    s' = applyChar c s

handleEvent :: State -> BrickEvent () CounterEvent -> EventM () (Next State)
-- handle ticks from the counter
handleEvent s (AppEvent (Counter i now)) = do
  let newState = tick s
  continue newState {counter = counter newState + 1, currentTime = now}
handleEvent s (VtyEvent (EvKey key [MCtrl])) =
  case key of
    -- control C, control D
    KChar 'c' -> halt $ s {loop = False}
    KChar 'd' -> halt $ s {loop = False}
    KChar 'w' -> continue $ applyBackspaceWord s
    KBS       -> continue $ applyBackspaceWord s
    _         -> continue s
handleEvent s (VtyEvent (EvKey key [MAlt])) =
  case key of
    KBS -> continue $ applyBackspaceWord s
    _   -> continue s
handleEvent s (VtyEvent (EvKey key [MMeta])) =
  case key of
    KBS -> continue $ applyBackspaceWord s
    _   -> continue s
handleEvent s (VtyEvent (EvKey key []))
  | hasEnded s =
    case key of
      KEsc -> halt $ s {loop = False}
      KEnter   -> halt $ s {loop = True}
      _      -> continue s
  | otherwise =
    case key of
      KChar c -> handleChar c s
      KEnter  -> handleChar '\n' s
      KBS     -> continue $ applyBackspace s
      KEsc    -> halt $ s {loop = False}
      _       -> continue s
handleEvent s _ = continue s

-- handleStartEvent runs when the app first starts up. It records the time  
-- the typing game should start. Note, this is different than when the user
-- starts typing.
handleStartEvent :: State -> EventM () State
handleStartEvent s = do
  now <- liftIO getCurrentTime
  let later = addUTCTime (secondsToNominalDiffTime $ fromIntegral $ howMuchOnCounter s) now
  return s {gameStartTime = later}

app :: Attr -> Attr -> Attr -> Attr -> App State CounterEvent ()
app hitAttr emptyAttr errorAttr resultAttr =
  App
    { appDraw = draw
    , appChooseCursor = showFirstCursor
    , appHandleEvent = handleEvent
    , appStartEvent = handleStartEvent
    , appAttrMap =
        const $
        attrMap
          defAttr
          [ 
            (hitAttrName, hitAttr)
          , (emptyAttrName, emptyAttr)
          , (errorAttrName, errorAttr)
          , (resultAttrName, resultAttr)
          ]
    }

data CounterEvent = Counter Int UTCTime

counterThread :: Brick.BChan.BChan CounterEvent -> IO ()
counterThread chan = do 
  now <- getCurrentTime
  Brick.BChan.writeBChan chan $ Counter 1 now

setTimer :: MVar Bool -> IO () -> Int -> IO ThreadId
setTimer stop ioOperation ms =
  forkIO $ f
  where
    f = do
      shouldStop <- takeMVar stop
      if shouldStop then
        return ()
      else do
          threadDelay (ms*1000)
          ioOperation
          putMVar stop False
          f

run :: Word8 -> Word8 -> Word8 -> State -> IO Bool
run fgHitCode fgEmptyCode fgErrorCode initialState = do
  stopFlag <- newEmptyMVar
  putMVar stopFlag False

  eventChan <- Brick.BChan.newBChan 10
  let buildVty = Graphics.Vty.mkVty Graphics.Vty.defaultConfig
  initialVty <- buildVty
  -- set a timer to keep running, controlled by the stop flag
  setTimer stopFlag (counterThread eventChan) 66
  finalState <- customMain initialVty buildVty
                    (Just eventChan) (app hitAttr emptyAttr errorAttr resultAttr) initialState

  -- Tell the timer to stop running
  putMVar stopFlag True
  return $ loop finalState
  where
    hitAttr = fg . ISOColor $ fgHitCode
    emptyAttr = fg . ISOColor $ fgEmptyCode
    errorAttr = flip withStyle bold . fg . ISOColor $ fgErrorCode
    -- abusing the fgErrorCode to use as a highlight colour for the results here
    resultAttr = fg . ISOColor $ fgErrorCode
