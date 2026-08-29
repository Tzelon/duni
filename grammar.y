program -> declaration* EOF ;

# *** Top level ***
declaration -> testDecl | funDecl | externDecl | comptimeDecl;


externDecl -> "KEYWORD_extern" "KEYWORD_fn" IDENTIFIER "(" parameters? ")" typeExpr NEWLINE ;
testDecl -> "KEYWORD_test" STRING? block ;
comptimeDecl -> "KEYWORD_comptime" block ;
funDecl -> "KEYWORD_fn" function ;
function -> IDENTIFIER "(" parameters? ")" typeExpr block ;
parameters -> ( paramDecl "," )*  paramDecl;
paramDecl -> IDENTIFIER typeExpr  
typeExpr -> IDENTIFIER ;

# *** Block level ***
statement -> exprStmt | printStmt | returnStmt | block;

# Not sure I want returnStmt
returnStmt -> "return" expression? NEWLINE ;

# `if` is an expression: block branches, no parens around the condition
# (a parenthesized condition is just a grouping expression). `else` is
# optional — an else-less `if` types as void (notes/control_flow.md).
ifExpr -> "if" expression block ( "else" ( block | ifExpr ) )? ;

block -> "{" statement* "}" ;

exprStmt -> expression NEWLINE ;
printStmt -> "print" expression ;

expression -> bind ;
# `=` is a binding (match), right-associative: `a = b = c` is `a = (b = c)`.
# The lhs is a pattern; rebinding an existing name is allowed (Elixir-style).
bind -> pattern "=" bind | logic_or ;
# Patterns are syntactically just expressions; which patterns are legal is
# decided during lowering (today: identifier only).
pattern -> expression ;

logic_or -> logic_and ( "or" logic_and )* ;
logic_and -> equality ( "and" equality )* ;

equality ->  comparison ( ("!=" | "==") comparison )* ;
comparison -> term ( (">" | ">=" | "<" | "<=") term )* ;
term -> factor ( ("-" | "+") factor )* ;
factor -> unary ( ("/" | "*") unary )* ;
unary -> ("-", "!") unary | call ;
call -> primary ( "(" arguments? ")" | "." IDENTIFIER )* ;
arguments -> expression ( "," expression )* ;
primary -> NUMBER | STRING | "true" | "false" | ifExpr | "(" expression ")" | IDENTIFIER ;
