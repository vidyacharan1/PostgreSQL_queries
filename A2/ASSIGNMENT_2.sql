CREATE TABLE department(
    dept_id CHAR(3) PRIMARY KEY,
    dept_name VARCHAR(40) NOT NULL UNIQUE
);



CREATE TABLE valid_entry(
    dept_id CHAR(3),
    entry_year INTEGER NOT NULL,
    seq_number INTEGER NOT NULL,
    FOREIGN KEY (dept_id) REFERENCES department(dept_id)
);



CREATE TABLE professor(
    professor_id VARCHAR(10) PRIMARY KEY,
    professor_first_name VARCHAR(40) NOT NULL,
    professor_last_name VARCHAR(40) NOT NULL,
    office_number VARCHAR(20),
    contact_number CHAR(10) NOT NULL,
    start_year INTEGER,
    resign_year INTEGER,
    dept_id CHAR(3),
    FOREIGN KEY (dept_id) REFERENCES department(dept_id),
    CHECK (start_year <= resign_year)
);



CREATE OR REPLACE FUNCTION iscour_idvalid(course_id CHAR(6))
RETURNS BOOLEAN AS $$
BEGIN
    RETURN (
        substring(course_id from 1 for 3) IN (SELECT dept_id FROM department) AND
        substring(course_id from 4 for 3) ~ '^[0-9]+$'
    );
END;
$$ LANGUAGE plpgsql;

CREATE TABLE courses(
    course_id CHAR(6) PRIMARY KEY NOT NULL,
    course_name VARCHAR(20) NOT NULL UNIQUE,
    course_desc TEXT,
    credits NUMERIC NOT NULL,
    dept_id CHAR(3),
    FOREIGN KEY (dept_id) REFERENCES department(dept_id),
    CHECK(credits > 0),
    CHECK (iscour_idvalid(course_id))
);



CREATE TABLE student(
    first_name VARCHAR(40) NOT NULL,
    last_name VARCHAR(40),
    student_id CHAR(11) PRIMARY KEY NOT NULL,
    address VARCHAR(100),
    contact_number CHAR(10) NOT NULL UNIQUE,
    email_id VARCHAR(50) UNIQUE,
    tot_credits INTEGER NOT NULL,
    dept_id CHAR(3),
    FOREIGN KEY (dept_id) REFERENCES department(dept_id),
    CHECK(tot_credits >= 0)
);



CREATE TABLE course_offers(
    course_id CHAR(6), 
    session VARCHAR(9),
    semester INTEGER NOT NULL,
    professor_id VARCHAR(10), 
    capacity INTEGER,
    enrollments INTEGER,
    PRIMARY KEY (course_id, session, semester),
    FOREIGN KEY (course_id) REFERENCES courses(course_id),
    FOREIGN KEY (professor_id) REFERENCES professor(professor_id),
    CHECK (semester = 1 OR semester = 2)
);



CREATE TABLE student_courses(
    student_id CHAR(11), 
    course_id CHAR(6),
    session VARCHAR(9),
    semester INTEGER,
    grade NUMERIC NOT NULL,
    FOREIGN KEY (course_id, session, semester) REFERENCES course_offers(course_id, session, semester),
    FOREIGN KEY (student_id) REFERENCES student(student_id),
    CHECK (grade >= 0 AND grade <= 10),
    CHECK (semester = 1 OR semester = 2)
);



CREATE OR REPLACE FUNCTION isvalid_check()
RETURNS TRIGGER AS $$
DECLARE
    ent_year INTEGER;
    depid CHAR(3);
    seq_num INTEGER;
BEGIN
    IF LENGTH(NEW.student_id) <> 10 THEN
        RAISE EXCEPTION 'invalid'; 
    END IF;

    ent_year := CAST(SUBSTRING(NEW.student_id FROM 1 FOR 4) AS INTEGER);
    depid := SUBSTRING(NEW.student_id FROM 5 FOR 3);
    seq_num := CAST(SUBSTRING(NEW.student_id FROM 8 FOR 3) AS INTEGER);

    IF EXISTS (
        SELECT 1
        FROM valid_entry
        WHERE dept_id = depid AND entry_year = ent_year AND seq_number = seq_num
    ) THEN
        RETURN NEW;
    ELSE
        RAISE EXCEPTION 'invalid';
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER validate_student_id
BEFORE INSERT ON student
FOR EACH ROW
EXECUTE FUNCTION isvalid_check();



CREATE OR REPLACE FUNCTION upd_seqnum()
RETURNS TRIGGER AS $$
DECLARE
    cur_seqnum INTEGER;
BEGIN
    SELECT seq_number INTO cur_seqnum 
    FROM valid_entry
    WHERE dept_id = NEW.dept_id AND entry_year = CAST(SUBSTRING(NEW.student_id FROM 1 FOR 4) AS integer);

    UPDATE valid_entry
    SET seq_number = cur_seqnum + 1
    WHERE dept_id = NEW.dept_id AND entry_year = CAST(SUBSTRING(NEW.student_id FROM 1 FOR 4) AS integer);

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_seq_number
AFTER INSERT ON student
FOR EACH ROW
EXECUTE FUNCTION upd_seqnum();



CREATE OR REPLACE FUNCTION isval_email()
RETURNS TRIGGER AS $$
BEGIN
    DECLARE
        student_id_part VARCHAR(10);
        dept_id_part VARCHAR(3);
        domain_part VARCHAR(20);
    BEGIN
        student_id_part := SUBSTRING(NEW.email_id FROM 1 FOR 10);
        dept_id_part := SUBSTRING(NEW.email_id FROM 12 FOR 3);
        domain_part := SUBSTRING(NEW.email_id FROM 15);

        IF POSITION('@' IN NEW.email_id) = 11 AND student_id_part = NEW.student_id AND dept_id_part = NEW.dept_id AND domain_part = '.iitd.ac.in' THEN
            RETURN NEW;
        ELSE
            RAISE EXCEPTION 'invalid';
        END IF;
    END;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER validate_student_email
BEFORE INSERT ON student
FOR EACH ROW
EXECUTE FUNCTION isval_email();



CREATE TABLE student_dept_change (
    old_student_id VARCHAR(11),
    old_dept_id CHAR(3),
    new_dept_id CHAR(3),
    new_student_id VARCHAR(11),
    FOREIGN KEY (old_dept_id) REFERENCES department(dept_id),
    FOREIGN KEY (new_dept_id) REFERENCES department(dept_id)
);



CREATE OR REPLACE FUNCTION log_student_dept_change()
RETURNS TRIGGER AS $$
DECLARE
    avg_grade NUMERIC;
    new_seq_number INTEGER;
BEGIN
    IF NEW.dept_id <> OLD.dept_id THEN
        
        IF EXISTS (
            SELECT 1
            FROM student_dept_change
            WHERE old_student_id = NEW.student_id
        ) THEN
            RAISE EXCEPTION 'Department can be changed only once';
        END IF;

        IF CAST(SUBSTRING(NEW.student_id FROM 1 FOR 4) AS INTEGER) < 2022 THEN
            RAISE EXCEPTION 'Entry year must be >= 2022';
        END IF;

        SELECT AVG(grade)
        INTO avg_grade
        FROM student_courses
        WHERE student_id = OLD.student_id;

        IF avg_grade <= 8.5 OR avg_grade IS NULL THEN
            RAISE EXCEPTION 'Low Grade';
        END IF;

        SELECT seq_number + 1 INTO new_seq_number
        FROM valid_entry
        WHERE dept_id = NEW.dept_id and entry_year=year;

        UPDATE student SET
            student_id = CONCAT(SUBSTRING(NEW.student_id FROM 1 FOR 7), LPAD(new_seq_number::TEXT, 3, '0')),
            email_id = CONCAT(SUBSTRING(NEW.student_id FROM 1 FOR 7), LPAD(new_seq_number::TEXT, 3, '0'), '@', NEW.dept_id, '.iitd.ac.in') 
        WHERE student_id = NEW.student_id;

        INSERT INTO student_dept_change (old_student_id, old_dept_id, new_dept_id, new_student_id)
        VALUES (NEW.student_id, OLD.dept_id, NEW.dept_id, CONCAT(SUBSTRING(NEW.student_id FROM 1 FOR 7), LPAD(new_seq_number::TEXT, 3, '0')));
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER log_student_dept_change
BEFORE UPDATE ON student
FOR EACH ROW
EXECUTE FUNCTION log_student_dept_change();



CREATE MATERIALIZED VIEW course_eval AS
SELECT
    course_id,
    session,
    semester,
    COUNT(*) AS number_of_students,
    AVG(grade) AS average_grade,
    MAX(grade) AS max_grade,
    MIN(grade) AS min_grade
FROM
    student_courses
GROUP BY
    course_id, session, semester;



CREATE OR REPLACE FUNCTION upd_credits()
RETURNS TRIGGER AS $$
DECLARE
    course_creds NUMERIC;
BEGIN
    SELECT credits INTO course_creds
    FROM courses
    WHERE course_id = NEW.course_id;

    UPDATE student
    SET tot_credits = tot_credits + course_creds
    WHERE student_id = NEW.student_id;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_tot_credits
AFTER INSERT ON student_courses
FOR EACH ROW
EXECUTE FUNCTION upd_credits();



CREATE OR REPLACE FUNCTION cred_limit()
RETURNS TRIGGER AS $$
DECLARE
    current_course_count INTEGER;
    current_tot_credits INTEGER;
    new_course_credits INTEGER;
BEGIN
    SELECT COUNT(*) INTO current_course_count
    FROM student_courses
    WHERE student_id = NEW.student_id AND session = NEW.session AND semester = NEW.semester;

    SELECT tot_credits INTO current_tot_credits
    FROM student
    WHERE student_id = NEW.student_id;

    SELECT credits INTO new_course_credits
    FROM courses
    WHERE course_id = NEW.course_id;

    IF current_course_count > 5 THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    IF current_tot_credits + new_course_credits > 60 THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER credit_limit_check
BEFORE INSERT ON student_courses
FOR EACH ROW
EXECUTE FUNCTION cred_limit();



CREATE OR REPLACE FUNCTION firstyr_credcheck()
RETURNS TRIGGER AS $$
DECLARE
    std_firstyr INTEGER;
BEGIN
    std_firstyr := CAST(SUBSTRING(NEW.student_id FROM 1 FOR 4) AS INTEGER);

    IF (SELECT credits FROM courses WHERE new.course_id = course_id) = 5 AND std_firstyr <> CAST(SUBSTRING(NEW.session FROM 1 FOR 4) AS INTEGER) THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER first_year_credit_check
BEFORE INSERT ON student_courses
FOR EACH ROW
EXECUTE FUNCTION firstyr_credcheck();



CREATE OR REPLACE FUNCTION check_capcourse()
RETURNS TRIGGER AS $$
DECLARE
    curr_enrollments INTEGER;
    course_capacity INTEGER;
BEGIN
        SELECT enrollments, capacity
        INTO curr_enrollments, course_capacity
        FROM course_offers
        WHERE course_id = NEW.course_id AND session = NEW.session AND semester = NEW.semester;

        IF curr_enrollments >= course_capacity THEN
            RAISE EXCEPTION 'course is full';
        END IF;
        
        UPDATE course_offers
        SET enrollments = enrollments + 1
        WHERE course_id = NEW.course_id AND session = NEW.session AND semester = NEW.semester;

        RETURN NEW;
    

END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_update_course_capacity
BEFORE INSERT ON student_courses
FOR EACH ROW
EXECUTE FUNCTION check_capcourse();



CREATE OR REPLACE FUNCTION del_studs_courdel()
RETURNS TRIGGER AS $$
BEGIN
    
    DELETE FROM student_courses
    WHERE course_id = OLD.course_id AND session = OLD.session AND semester = OLD.semester;

    UPDATE student
    SET tot_credits = tot_credits - OLD.credits
    WHERE student_id IN (
        SELECT student_id
        FROM student_courses
        WHERE course_id = OLD.course_id AND session = OLD.session AND semester = OLD.semester
    );

    RETURN OLD;
END;
$$ LANGUAGE plpgsql;


CREATE OR REPLACE FUNCTION check_courseprof()
RETURNS TRIGGER AS $$
BEGIN
    
    IF NOT EXISTS (
        SELECT 1
        FROM courses
        WHERE course_id = NEW.course_id
    ) THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM professor
        WHERE professor_id = NEW.professor_id
    ) THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;


CREATE TRIGGER delete_students
BEFORE DELETE ON course_offers
FOR EACH ROW
EXECUTE FUNCTION del_studs_courdel();

CREATE TRIGGER check_course_professor
BEFORE INSERT ON course_offers
FOR EACH ROW
EXECUTE FUNCTION check_courseprof();



CREATE OR REPLACE FUNCTION num_coursesprof()
RETURNS TRIGGER AS $$
DECLARE
    course_count INTEGER;
    resign_year_prof INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO course_count
    FROM course_offers
    WHERE professor_id = NEW.professor_id AND session = NEW.session;

    IF course_count > 4 THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    SELECT resign_year INTO resign_year_prof
    FROM professor
    WHERE professor_id = new.professor_id;

    IF resign_year_prof IS NOT NULL AND resign_year_prof < CAST(SUBSTRING(NEW.session FROM 1 FOR 4) AS INTEGER) THEN
        RAISE EXCEPTION 'invalid';
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER check_professor_course_limit
BEFORE INSERT ON course_offers
FOR EACH ROW
EXECUTE FUNCTION num_coursesprof();



CREATE OR REPLACE FUNCTION upd_del_department()
RETURNS TRIGGER AS $$
BEGIN
    IF OLD.dept_id IS DISTINCT FROM NEW.dept_id THEN
        UPDATE course_offers
        SET course_id = NEW.dept_id || SUBSTRING(course_id FROM 4)
        WHERE course_id LIKE OLD.dept_id || '___%';

        UPDATE courses
        SET course_id = NEW.dept_id || SUBSTRING(course_id FROM 4)
        WHERE course_id LIKE OLD.dept_id || '___%';

        UPDATE student_courses
        SET course_id = NEW.dept_id || SUBSTRING(course_id FROM 4)
        WHERE course_id LIKE OLD.dept_id || '___%';

        UPDATE professor
        SET dept_id = NEW.dept_id
        WHERE dept_id = OLD.dept_id;

        UPDATE student
        SET dept_id = NEW.dept_id
        WHERE dept_id = OLD.dept_id;
    END IF;


    IF TG_OP = 'DELETE' AND EXISTS (SELECT 1 FROM student WHERE dept_id = OLD.dept_id) THEN
        RAISE EXCEPTION 'Department has students';
    ELSE
        
        DELETE FROM professor WHERE dept_id = OLD.dept_id;  
        DELETE FROM course_offers WHERE course_id LIKE OLD.dept_id || '___%';
        DELETE FROM courses WHERE course_id LIKE OLD.dept_id || '___%';

        RETURN OLD;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_delete_department
BEFORE UPDATE OR DELETE ON department
FOR EACH ROW
EXECUTE FUNCTION upd_del_department();
