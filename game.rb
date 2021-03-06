require 'active_support'
require 'active_support/core_ext/object'
require 'active_support/core_ext/array'
require 'octokit'
require 'chess'
require 'imgkit'
require 'redcarpet'

# CONSTANTS
SHARE_GAME_TEXT = <<~SHARE_END
Invite a friend to take the next turn! 
[Share on Twitter...](https://twitter.com/share?text=I'm+playing+chess+on+a+GitHub+Profile+Readme!+I+just+moved.+You+have+the+next+move+at+https://github.com/rahatzamancse/github-chess)
SHARE_END

@preview_headers = [
    ::Octokit::Preview::PREVIEW_TYPES[:reactions],
    ::Octokit::Preview::PREVIEW_TYPES[:integrations]
]

def error_notification(repo_nwo, issue_num, reaction, new_comment_body, e=nil)
    @octokit.create_issue_reaction(repo_nwo, issue_num, reaction, {accept: @preview_headers})
    @octokit.add_comment(repo_nwo, issue_num, new_comment_body)
    @octokit.close_issue(repo_nwo, issue_num)
    if e.present?
        puts '-----------'
        puts "Exception: #{e}"
        puts '-----------'
        puts "Backtrace: #{e.backtrace}"
        puts '-----------'
    end
end

# Environment Variables
REPOSITORY         = ENV.fetch('REPOSITORY')
EVENT_ISSUE_NUMBER = ENV.fetch('EVENT_ISSUE_NUMBER')
EVENT_ISSUE_TITLE  = ENV.fetch('EVENT_ISSUE_TITLE')
EVENT_USER_LOGIN   = ENV.fetch('EVENT_USER_LOGIN')
RAHAT_REPO         = 'rahatzamancse/github-chess'

# Authenticate using GITHUB_TOKEN
@octokit = Octokit::Client.new(access_token: ENV.fetch('GITHUB_SECRET'))
@octokit.auto_paginate = true
@octokit.default_media_type = ::Octokit::Preview::PREVIEW_TYPES[:integrations]

# Show we've got eyes on the triggering comment.
@octokit.create_issue_reaction(
    REPOSITORY,
    EVENT_ISSUE_NUMBER,
    'eyes',
    {accept: @preview_headers}
)
@octokit.create_issue_reaction(
    REPOSITORY,
    EVENT_ISSUE_NUMBER,
    'rocket',
    {accept: @preview_headers}
)


#
# Parse the issue title.
# ------------------------
begin
    # validate we can parse title Chess|new|e3c2|1
    title_split = EVENT_ISSUE_TITLE.gsub(/^"+|"+$/, '').split('|')
    CHESS_GAME_NUM   = title_split&.fourth || EVENT_ISSUE_NUMBER.to_s
    CHESS_GAME_TITLE = title_split&.first.to_s + CHESS_GAME_NUM
    CHESS_GAME_CMD   = title_split&.second.to_s
    CHESS_USER_MOVE  = title_split&.third.to_s
    raise StandardError.new 'CHESS_GAME_TITLE is blank' if CHESS_GAME_TITLE.blank?
    raise StandardError.new 'CHESS_USER_MOVE is blank'  if CHESS_USER_MOVE.blank? && CHESS_GAME_CMD == 'move'
    raise StandardError.new 'new|move are the only allowed commands' unless ['new','move'].include? CHESS_GAME_CMD
rescue StandardError => e
    comment_text = "@#{EVENT_USER_LOGIN} The game title or move was unable to be parsed."
    error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
    exit(0)
end

GAME_DATA_PATH = './chess-games/chess.pgn'
game = nil
game_content = nil

#
# Get the contents of the game board.
# ---------------------------------------
begin
    game_content = File.open(GAME_DATA_PATH).read
rescue StandardError => e
    # no file exists... so no game... so... go ahead and create it
    game = Chess::Game.new
else
    game = if CHESS_GAME_CMD == 'new' || game.present?
            Chess::Game.new
        else
            # Game is in progress. Load the game board.
            begin
                Chess::Game.load_pgn GAME_DATA_PATH
            rescue StandardError => e
                comment_text = "@#{EVENT_USER_LOGIN} Game data couldn't loaded: #{GAME_DATA_PATH}. I am sorry. I will look ahead to solve this soon. Feel free to give a PR if you want :)"
                error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
                exit(0)
            end
        end
end

if CHESS_GAME_CMD == 'new' && game_content.present?
    begin
        @octokit.delete_contents(
            REPOSITORY,
            GAME_DATA_PATH,
            "@#{EVENT_USER_LOGIN} delete to allow new game",
            game_content&.sha,
            branch: 'master',
        )
    rescue StandardError => e
        comment_text = "@#{EVENT_USER_LOGIN} Game data #{GAME_DATA_PATH} couldn't be deleted to create new game :("
        error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
        exit(0)
    end
end



begin
    issues = @octokit.list_issues(
        REPOSITORY,
        state: 'closed',
        accept: @preview_headers
    )&.select{ |issue| issue&.reactions.confused == 0 }

rescue StandardError => e
    # don't exit, if these can't be retrieved. Allow play to continue.
end



# Share the play. Exit if user just had the prior move.
if CHESS_GAME_CMD == 'move'
    # 
    # Need to filter out and PRs and other issues.
    # ---------------------------------------
    i = 0
    issues&.each do |issue|
        break if issue.title.start_with? 'chess|new'
        if issue.title.start_with?('chess|move|') && REPOSITORY == RAHAT_REPO
            if issue.user.login == EVENT_USER_LOGIN
                comment_text = "@#{EVENT_USER_LOGIN} Slow down! You _just_ moved, so can't immediately take the next turn. #{SHARE_END}"
                error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
                exit(0)
            end
            i += 1
        end
        break if i >= 1
    end

    #
    # Perform Move
    # ---------------------------------------
    begin
        game.move(CHESS_USER_MOVE) # ie move('e2e4', …, 'b1c3')
    rescue Chess::IllegalMoveError => e
        comment_text = "@#{EVENT_USER_LOGIN} Whaaa.. '#{CHESS_USER_MOVE}' is an invalid move! Usually this is because someone squeezed a move in just before you."
        error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
        exit(0)
    end

    #
    # Game over thanks for playing.
    # ---------------------------------------
    if game.over?
        # add label = end
        @octokit.add_labels_to_an_issue(REPOSITORY, EVENT_ISSUE_NUMBER, ["game-over"])
        game_stats = { 
            moves: 0,
            players: [],
            start_time: nil,
            end_time: nil 
        }
        issues&.each do |issue|
            break if issue.title.start_with? 'chess|new'
            if game_stats[:moves] == 0
                game_stats[:end_time] = issue.created_at
            end
            game_stats[:moves] += 1
            if REPOSITORY == RAHAT_REPO
                game_stats[:players].push "@#{issue.user.login}"
            else
                game_stats[:players].push "#{issue.user.login}"
            end
            game_stats[:start_time] = issue.created_at
        end
        game_stats[:players] = game_stats[:players]&.uniq
        hours = (game_stats[:start_time] - game_stats[:end_time]).to_i.abs / 3600

        @octokit.add_comment(
            REPOSITORY,
            EVENT_ISSUE_NUMBER,
            "That's game over! Thank you for playing that chess game. That game had #{game_stats[:moves]} moves, #{game_stats[:players]&.length} players, and went for #{hours} hours. Let's play again at https://github.com/rahatzamancse/github-chess.\n\nPlayers that game: #{game_stats[:players].join(', ')}"
        )
    end
end


@octokit.add_comment(
    REPOSITORY,
    EVENT_ISSUE_NUMBER,
    "@#{EVENT_USER_LOGIN} Done. View back at https://github.com/rahatzamancse/github-chess\n\n#{SHARE_GAME_TEXT}"
)

@octokit.close_issue(REPOSITORY, EVENT_ISSUE_NUMBER)


#
# Update README.md
# ---------------------------------------

# visually represent the board
# generate new comment links
#   - and "what possible valid moves are for each piece"

cols = ('a'..'h').to_a
rows = (1..8).to_a

# list squares on the board - format a1, a2, a3, b1, b2, b3 etc
squares = []
cols.each do |col|
    rows.each do |row|
        squares.push "#{col}#{row}"
    end
end

# combine squares with where they can MOVE to
next_move_combos = squares.map { |from| {from: from, to: squares} }

TMP_FILENAME = "/tmp/chess.pgn"
fake_game = if CHESS_GAME_CMD == 'move'
                File.write TMP_FILENAME, game.pgn.to_s
                Chess::Game.load_pgn TMP_FILENAME
            else
                Chess::Game.new
            end

# delete squares not valid for next move
good_moves = []
next_move_combos.each do |square|
    square[:to].each do |to|
        move_command = "#{square[:from]}#{to}"
        fake_game_tmp = if CHESS_GAME_CMD == 'move'
                            File.write TMP_FILENAME, fake_game.pgn.to_s
                            Chess::Game.load_pgn TMP_FILENAME
                        else
                            Chess::Game.new
                        end
        begin
            fake_game_tmp.move move_command
        rescue Chess::IllegalMoveError => e
            # puts "move: #{move_command} (bad)"
        else
            # puts "move: #{move_command} (ok)"
            if good_moves.select{ |move| move[:from] == square[:from] }.blank?
                good_moves.push({ from: square[:from], to: [to] })
            else
                good_moves.map do |move|
                    if move[:from] == square[:from]
                        {
                            from: move[:from],
                            to:   move[:to].push(to)
                        }
                    else
                        move
                    end
                end
            end
        end
    end
end


game_state =  case game.status.to_s
            when 'in_progress'
                'Game is in progress.'
            when 'white_won'
                'Game won by white with a checkmate.'
            when 'black_won'
                'Game won by black with a checkmate.'
            when 'white_won_resign'
                'Game won by white for resign.'
            when 'black_won_resign'
                'Game won by black for resign.'
            when 'stalemate'
                'Game was a draw due to stalemate.'
            when 'insufficient_material'
                'Game was a draw due to insufficient material to checkmate.'
            when 'fifty_rule_move'
                'Game was a draw due to fifty rule move.'
            when 'threefold_repetition'
                'Game was a draw due to threefold repetition.'
            else
                'Game terminated. Something went wrong.'
            end

new_readme = <<~HTML

## Community Chess Tournament

**#{game_state}** This is open to ANYONE to play the next move. That's the point. :smile:  It's your turn! Move a #{(game.board.active_color) ? 'black' : 'white'} piece.

HTML

board = {
    "8": { a: 56, b: 57, c: 58, d: 59, e: 60, f: 61, g: 62, h: 63 },
    "7": { a: 48, b: 49, c: 50, d: 51, e: 52, f: 53, g: 54, h: 55 },
    "6": { a: 40, b: 41, c: 42, d: 43, e: 44, f: 45, g: 46, h: 47 },
    "5": { a: 32, b: 33, c: 34, d: 35, e: 36, f: 37, g: 38, h: 39 },
    "4": { a: 24, b: 25, c: 26, d: 27, e: 28, f: 29, g: 30, h: 31 },
    "3": { a: 16, b: 17, c: 18, d: 19, e: 20, f: 21, g: 22, h: 23 },
    "2": { a:  8, b:  9, c: 10, d: 11, e: 12, f: 13, g: 14, h: 15 },
    "1": { a:  0, b:  1, c:  2, d:  3, e:  4, f:  5, g:  6, h:  7 },
}

actual_board = <<~MY_BOARD
| X | A | B | C | D | E | F | G | H |
| - | - | - | - | - | - | - | - | - |
MY_BOARD

(1..8).to_a.reverse.each_with_index do |row|
    a = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:a]] || 'blank').to_s}.png)"
    b = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:b]] || 'blank').to_s}.png)"
    c = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:c]] || 'blank').to_s}.png)"
    d = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:d]] || 'blank').to_s}.png)"
    e = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:e]] || 'blank').to_s}.png)"
    f = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:f]] || 'blank').to_s}.png)"
    g = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:g]] || 'blank').to_s}.png)"
    h = "![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/#{(game.board[board[:"#{row}"][:h]] || 'blank').to_s}.png)"

    actual_board.concat "| #{row} | #{a} | #{b} | #{c} | #{d} | #{e} | #{f} | #{g} | #{h} |\n"
end

new_readme.concat actual_board

if game.over?
    new_readme.concat <<~HTML

    ## Play again? [![](https://raw.githubusercontent.com/#{REPOSITORY}/master/chess_images/new_game.png)](https://github.com/#{REPOSITORY}/issues/new?title=chess%7Cnew)

HTML

else
    new_readme.concat <<~HTML

    #### **#{(game.board.active_color) ? 'BLACK' : 'WHITE'}:** It's your move... to choose _where_ to move..

    | FROM | TO - _just click one of the links_ :) |
    | ---- | -- |
HTML

    good_moves.each do |move|
        new_readme.concat "| **#{move[:from].upcase}** | #{move[:to].map{|a| "[#{a.upcase}](https://github.com/#{REPOSITORY}/issues/new?title=chess%7Cmove%7C#{move[:from]}#{a}%7C#{CHESS_GAME_NUM}&body=Just+push+%27Submit+new+issue%27.+You+don%27t+need+to+do+anything+else.)"}.join(' , ')} |\n"
    end
end


new_readme.concat <<~HTML

#{SHARE_GAME_TEXT}

**How this works**

When you click a link, it opens a GitHub Issue with the required pre-populated text. Just push "Create New Issue". That will trigger a [GitHub Actions](https://github.blog/2020-07-03-github-action-hero-casey-lee/#getting-started-with-github-actions) workflow that'll update my GitHub Profile `README.md` with the new state of the board.

**Notice a problem?**

Raise an [issue](https://github.com/#{REPOSITORY}/issues), and include the text _cc @rahatzamancse_.

**Last few moves, this game**

| Move  | Who |
| ----- | --- |
HTML

new_readme.concat "| #{CHESS_USER_MOVE[0..1].to_s.upcase} to #{CHESS_USER_MOVE[2..3].to_s.upcase} | [@#{EVENT_USER_LOGIN}](https://github.com/#{EVENT_USER_LOGIN}) |\n"

if issues.present? # just in case, the API is down, or there's no response, don't let that prevent the game rendering
    i = 0
    issues.each do |issue|
        break if issue.title.start_with? 'chess|new'
        if issue.title.start_with? 'chess|move|'
            from = issue.title&.split('|')&.third.to_s[0..1].to_s.upcase
            to = issue.title&.split('|')&.third.to_s[2..3].to_s.upcase
            who = issue.user.login
            i += 1
            new_readme.concat "| [@#{who}](https://github.com/#{who}) | #{from} to #{to} |\n"
        end
        break if i >= 4
    end
else
    new_readme.concat "| ¯\\_(ツ)_/¯ | History temporarily unavailable. |\n"
end

new_readme.concat <<~HTML

**Top 20 Leaderboard: Most moves across all games, except me.**

| Moves | Who |
| ----- | --- |
HTML

if issues.present?
    moves = issues.select{|issue| issue.title.start_with? 'chess|move|'}.map{ |issue| issue.user.login }&.group_by(&:itself)&.except("rahatzamancse")&.transform_values(&:size).sort_by{|name,moves| moves }.reverse[0..19]
    moves.each do |move|
        new_readme.concat "| #{move[1]} | [@#{move[0]}](https://github.com/#{move[0]}) |\n"
    end
else
    new_readme.concat "| ¯\\_(ツ)_/¯ | History temporarily unavailable. |\n"
end

#
# Render the image of the board
# ---------------------------------------
begin
    renderer = Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(), tables: true)
    board_html_content = renderer.render(actual_board)
    kit = IMGKit.new(board_html_content, width: 0, height: 0)
    kit.stylesheets << './renders/style.css'
    board_jpg_content = kit.to_img
rescue StandardError => e
    comment_text = "@#{EVENT_USER_LOGIN} Couldn't create the image of the board. Move *was* saved, however."
    error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
    exit(0)
end


#
# Update the game with next moves.
# ---------------------------------------
begin
    # Get the master branch
    latest_commit_sha = @octokit.ref(REPOSITORY, 'heads/master').object.sha
    base_tree_sha = @octokit.commit(REPOSITORY, latest_commit_sha).commit.tree.sha

    all_files = [
        ['README.md', new_readme, 'utf-8'],
        ['renders/board.html', board_html_content, 'utf-8'],
        ['renders/board.jpg', board_jpg_content, 'base64'],
        ['chess_games/chess.pgn', game.pgn.to_s, 'utf-8']
    ]

    new_tree = all_files.map do |path, new_content, encoding|
        Hash(
            path: path,
            mode: "100644",
            type: "blob",
            sha: @octokit.create_blob(REPOSITORY, encoding == 'base64' ? Base64.encode64(new_content) : new_content, encoding)
        )
    end

    # Create a commit
    new_tree_sha = @octokit.create_tree(REPOSITORY, new_tree, base_tree: base_tree_sha).sha
    commit_message = "@#{EVENT_USER_LOGIN} move #{CHESS_USER_MOVE}"
    new_commit_sha = @octokit.create_commit(REPOSITORY, commit_message, new_tree_sha, latest_commit_sha).sha

    # Push
    updated_ref = @octokit.update_ref(REPOSITORY, "heads/master", new_commit_sha)

rescue StandardError => e
    comment_text = "@#{EVENT_USER_LOGIN} Couldn't update render of the game board. Move *was* saved, however."
    error_notification(REPOSITORY, EVENT_ISSUE_NUMBER, 'confused', comment_text, e)
    exit(0)
end