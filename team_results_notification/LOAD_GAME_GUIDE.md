# Load New Game from Excel - User Guide

## Overview
The "Load New Game" feature allows administrators to upload Excel files containing game data and automatically create separate games for each sheet in the Excel file.

## Excel File Requirements

### File Format
- **File Type**: Excel files (.xlsx or .xls)
- **Sheets**: Can have any number of sheets (1 or more)
- **Each Sheet**: Will become a separate game in the system
- **Empty Sheets**: Will create empty games

### Game Naming
- Each sheet becomes a separate game with name: `{filename}_{sheet_name}`
- Example: `QuizGame.xlsx` with sheets "Questions", "Tiers", "Answers" creates:
  - Game: `quizgame_questions`
  - Game: `quizgame_tiers` 
  - Game: `quizgame_answers`

### Database Structure
The system will automatically create:
- **One games_list entry** for each sheet (separate games)
- **One database table** for each sheet (same name as game)
- **Data import** from each sheet to its corresponding table

## How to Use

### Step 1: Access Game Management
1. Login as an admin user
2. Navigate to "Game Management" from the main page
3. Click on "Load New Game" button

### Step 2: Upload Excel File
1. Click "Choose File" button
2. Select your Excel file (.xlsx or .xls)
3. Verify the file is selected (green checkmark appears)
4. Click "Load Game" to process the file

### Step 3: Processing
- The system will validate the Excel file
- Create a separate game for each sheet
- Create database tables for each sheet
- Insert all data from each sheet to its table
- Create individual GamesList entries for each game

## Example Excel Structure

### Sheet 1: "Tiers" (Game Tiers Data)
| Tier | Name | Points | Difficulty |
|------|------|--------|------------|
| 1 | Easy | 10 | Beginner |
| 2 | Medium | 20 | Intermediate |
| 3 | Hard | 30 | Advanced |

### Sheet 2: "Questions" (Game Questions Data)
| Question | Answer | Points | Category | Tier |
|----------|--------|--------|----------|------|
| What is 2+2? | 4 | 10 | Math | 1 |
| What is the capital of France? | Paris | 20 | Geography | 2 |

### Sheet 3: "Categories" (Game Categories Data)
| Category | Description | Color |
|----------|-------------|-------|
| Math | Mathematics questions | Blue |
| Geography | Geography questions | Green |
| History | History questions | Red |

## Database Structure Created

### GamesList Entries (3 separate games)
1. **Game 1**: `quizgame_tiers`
   - **game_name**: "quizgame_tiers"
   - **game_description**: "Sheet 'Tiers' from Excel file 'QuizGame' with 3 rows"

2. **Game 2**: `quizgame_questions`
   - **game_name**: "quizgame_questions" 
   - **game_description**: "Sheet 'Questions' from Excel file 'QuizGame' with 2 rows"

3. **Game 3**: `quizgame_categories`
   - **game_name**: "quizgame_categories"
   - **game_description**: "Sheet 'Categories' from Excel file 'QuizGame' with 3 rows"

### Database Tables (3 separate tables)
- **quizgame_tiers**: Contains all data from "Tiers" sheet
- **quizgame_questions**: Contains all data from "Questions" sheet  
- **quizgame_categories**: Contains all data from "Categories" sheet

## Error Handling

### Common Errors
1. **"Excel file must have at least 1 sheet"**
   - Solution: Ensure your Excel file has at least 1 sheet

2. **"Game name 'quizgame_questions' already exists"**
   - Solution: Use a different filename or delete the existing games

3. **"Table already exists"**
   - Solution: The generated table names conflict with existing tables

4. **"Invalid table name generated"**
   - Solution: Use simpler sheet names without special characters

### Best Practices
- Use simple, descriptive sheet names
- Avoid special characters in sheet names
- Ensure data is properly formatted in Excel
- Test with small files first
- Empty sheets will create empty games
- Each sheet becomes a separate game and database table

## Technical Details

### Backend Processing
1. Receives base64-encoded Excel file
2. Decodes and parses using pandas
3. Validates sheet count and structure
4. Creates separate game for each sheet
5. Creates MySQL tables dynamically for each sheet
6. Inserts all data from each sheet to its table
7. Creates individual GamesList entries for each game
8. Returns detailed information about all created games

### Security
- File validation on upload
- SQL injection protection
- Table name sanitization
- Error handling and rollback

## Support
For issues or questions about the Load New Game feature, contact the system administrator.
