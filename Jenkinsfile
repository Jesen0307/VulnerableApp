pipeline {
    agent any

    environment {
        REPORTS_DIR = 'security-reports'
        SONAR_HOST_URL = 'http://localhost:9000'
        SONAR_TOKEN = 'sqa_c18b9398b7904f6dce239a5d4902c0b39ef776d0'
        SONAR_PROJECT_KEY = 'VulnerableApp'
    }

    stages {
        stage('Install Dependencies') {
            steps {
                sh '''
                    sudo apt-get update
                    sudo apt-get install -y python3 python3-pip python3-venv curl docker.io openjdk-17-jdk
                    sudo systemctl start docker
                    sudo pip3 install semgrep --break-system-packages || sudo pip3 install semgrep
		    
                '''
            }
        }

        // This is a Gradle + Java project. SonarQube's Java analyzer requires
        // compiled class files (sonar.java.binaries), so we must build the
        // code BEFORE running the SAST analysis.
        stage('Build (Compile Java)') {
            steps {
                sh 'chmod +x gradlew'
                sh './gradlew classes --no-daemon'
            }
        }

        stage('Security Analysis') {
            steps {
                script {
                    sh 'mkdir -p $REPORTS_DIR'

                    // Run Semgrep and SonarQube scans in parallel
                    parallel (
                        'Semgrep SAST': {
                            sh 'chmod +x scripts/semgrep-scan.sh'
                            sh './scripts/semgrep-scan.sh . $REPORTS_DIR'
                        },
                        'SonarQube Analysis': {
                            sh 'chmod +x scripts/sonarqube-scan.sh'
                            // Compiled classes are in build/classes/java/main, which
                            // the script auto-detects.
                            sh './scripts/sonarqube-scan.sh . $SONAR_PROJECT_KEY $SONAR_HOST_URL $SONAR_TOKEN $REPORTS_DIR'
                        }
                    )
                }
            }
        }

        stage('Deduplicate Findings') {
            steps {
                sh 'python3 scripts/security_processor.py --workspace $REPORTS_DIR'
            }
        }
    }

    post {
        always {
            echo 'Pipeline execution completed.'
            archiveArtifacts artifacts: "$REPORTS_DIR/*.json, $REPORTS_DIR/*.log", allowEmptyArchive: true
        }
    }
}
# PR trigger: Mon Sep  7 14:37:24 +07 2026
